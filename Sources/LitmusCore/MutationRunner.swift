internal import AemiRuntime
internal import Foundation
internal import SourceCorpus

/// Which test harness a host package uses.
public enum HarnessSelection: String, Codable, Sendable {
    /// Built bundles run directly, in parallel, falling back to `swift test` when the layout is not understood.
    case automatic
    /// `swift test` per execution: one worker, slowest, fewest assumptions.
    case swiftTest
}

/// How a mutant's first failing run becomes a kill.
public enum KillConfirmation: String, Codable, Sendable {
    /// The first failure after activation is the kill. Fastest; a load-sensitive test can make false kills.
    case none
    /// The failing tests are rerun alone, with the mutant active (they must fail and reach it) and inactive (they must
    /// pass). Without test identities (XCTest, `swift test`, Xcode), the whole suite is rerun alone instead.
    case targeted
    /// An inactive whole-suite control and a second active whole-suite run, alone.
    case full
}

/// Execution options; every bound is checked before anything runs.
public struct RunOptions: Sendable {
    public var exclude: [String] = []
    /// Maximum non-overlapping sites per schema build, 1...256.
    public var batchSize = 64
    /// Deadline of one build, in seconds.
    public var buildTimeout = 900
    /// Upper bound of the per-suite deadline, in seconds; the deadline itself derives from the baseline.
    public var timeoutCap = 300
    /// Deadline = max(`minimumTimeout`, baseline × `timeoutFactor` + 2 s), at most `timeoutCap`.
    public var timeoutFactor = 4
    public var minimumTimeout = 3
    /// Mutants tested at once when the harness allows it.
    public var jobs = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
    public var harness: HarnessSelection = .automatic
    /// Stop a mutant's suite at its first structured failure (Swift Testing event stream).
    public var failFast = true
    /// How a first failing run is confirmed (the fcheck pilot found load-sensitive tests making false kills).
    public var killConfirmation = KillConfirmation.targeted
    public var keepWorkspace = false

    public init() {}

    func validate() throws {
        guard (1...256).contains(batchSize), (1...86_400).contains(buildTimeout), (1...86_400).contains(timeoutCap),
            (1...100).contains(timeoutFactor), (1...86_400).contains(minimumTimeout), minimumTimeout <= timeoutCap,
            (1...256).contains(jobs)
        else { throw LitmusFailure("batch size, deadlines or jobs outside documented bounds") }
    }
}

/// A worker's private directory, from aemi's `ResourcePool`: markers and `TMPDIR` of the runs it hosts live under it.
struct WorkerSlot: PooledResource {
    let directory: String
    init?(path: String) {
        let directory = path + "/worker-" + UUID().uuidString.prefix(8)
        guard (try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)) != nil
        else { return nil }
        self.directory = directory
    }
}

/// Builds conflict-free schemas once per batch, isolates mutants that do not compile, measures which mutants the
/// suite reaches, and tests the reached ones in parallel.
///
/// Policy (`RunArtifact.executionPolicy`):
/// - The unmutated build and suite must pass; every schema's inactive control must pass with the baseline's counts.
/// - A mutant the control never reached is `noCoverage`, without running it.
/// - A failure counts only when the mutant's own marker shows its code ran; a failure without activation is rerun
///   alone, and stays an infrastructure error if it repeats.
/// - A crash is rerun alone and counts when it repeats; a timeout is rerun alone with twice the deadline.
/// - A schema that does not compile is split by its compiler diagnostics, then by halves, until each mutant that does
///   not compile alone is `unviable`.
public struct MutationRunner<Executor: ProcessExecutor>: Sendable {
    private let executor: Executor
    public init(executor: Executor) { self.executor = executor }

    /// Creates an owned snapshot, validates the baselines, then decides every site.
    /// - Important: Only run on trusted project code; copying is not a security sandbox.
    /// - Throws: On baseline failure, cancellation or artifact/I/O failure; the checkpoint and the journal keep the
    ///   decisions made so far.
    public func run(driver: BuildDriver, outputDirectory: String, options: RunOptions = RunOptions()) async throws
        -> RunArtifact
    {
        try options.validate()
        let clock = ContinuousClock()
        let started = clock.now
        let fm = FileManager.default
        let output = SourcePath.canonical(outputDirectory), root = SourcePath.canonical(driver.root)
        guard output != root, !output.hasPrefix(root + "/"), !fm.fileExists(atPath: output) else {
            throw LitmusFailure("run directory must be new and outside original source root")
        }
        let logs = output + "/logs", artifacts = output + "/artifacts", workers = output + "/workers"
        for directory in [output, logs, artifacts, workers] {
            try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        var timings: [String: Double] = [:]
        func account(_ phase: String, since start: ContinuousClock.Instant) {
            timings[phase, default: 0] += seconds(clock.now - start)
        }

        var phase = clock.now
        let snapshot = try await WorkspaceSnapshot.create(source: root, destination: output + "/workspace")
        account("snapshot", since: phase)
        phase = clock.now
        let clonePlan = try await MutationPlanner.plan(root: snapshot.root, exclude: options.exclude, jobs: 8)
        account("plan", since: phase)
        let plan = MutationPlan(
            root: root,
            analyzedFiles: clonePlan.analyzedFiles,
            mutations: clonePlan.mutations,
            suppressed: clonePlan.suppressed,
            notes: clonePlan.notes
        )
        guard !plan.mutations.isEmpty else {
            throw LitmusFailure("no mutable production sites; inspect plan exclusions")
        }
        guard Set(plan.mutations.map(\.id)).count == plan.mutations.count else {
            throw LitmusFailure("mutation ID collision")
        }
        let toolchain = try await executor.execute(
            ToolCommand(
                executable: "/usr/bin/xcrun",
                arguments: [driver.usesXcode ? "xcodebuild" : "swift", "-version"]
            ),
            directory: snapshot.root,
            environment: subjectEnvironment(nil),
            timeout: 60
        )
        guard toolchain.exitStatus == 0 else { throw LitmusFailure("toolchain identification failed") }
        let provenance = RunProvenance(
            toolVersion: LitmusVersion.current,
            snapshotSHA256: snapshot.digest,
            inputs: snapshot.entries,
            driver: driver,
            toolchain: String(decoding: toolchain.stdout, as: UTF8.self),
            startedAt: ISO8601DateFormatter().string(from: Date()),
            executionPolicy: RunArtifact.executionPolicy
        )
        var artifact = RunArtifact(provenance: provenance, plan: plan)
        let checkpointPath = output + "/run.json"
        try ArtifactCodec.write(artifact, path: checkpointPath)
        let journal = try ResultJournal(path: output + "/results.journal")

        do {
            phase = clock.now
            let baselineBuild = try await executor.execute(
                driver.buildCommand(workspace: snapshot.root, artifacts: artifacts),
                directory: snapshot.root,
                environment: subjectEnvironment(nil),
                timeout: options.buildTimeout
            )
            try writeLog(baselineBuild, path: logs + "/baseline-build.log")
            account("build", since: phase)
            guard baselineBuild.exitStatus == 0, !baselineBuild.timedOut else {
                throw LitmusFailure("unmutated build failed; no mutant verdicts are valid (logs/baseline-build.log)")
            }
            phase = clock.now
            var harnessNotes: [String] = []
            let harness = try await makeHarness(
                driver: driver,
                options: options,
                workspace: snapshot.root,
                artifacts: artifacts,
                logs: logs,
                notes: &harnessNotes
            )
            artifact.notes += harnessNotes
            account("discovery", since: phase)
            let allowedWorkers = min(options.jobs, harness.maximumWorkers)
            let pool = try ResourcePool<WorkerSlot>(diagnostic: workers, count: allowedWorkers)
            let current = Judge(
                harness: harness,
                pool: pool,
                options: options,
                baseline: TestCounts(passed: 0, failed: 0, skipped: 0),
                deadline: options.timeoutCap,
                parallelDeadline: options.timeoutCap,
                rerunDeadline: options.timeoutCap
            )
            phase = clock.now
            let usageBefore = ChildUsage.cpuSeconds()
            let baseline = try await current.execute(name: "baseline", activeID: "", deadline: options.timeoutCap)
            let suiteCPU = ChildUsage.cpuSeconds() - usageBefore
            account("tests", since: phase)
            guard baseline.result.outcome == .passed, let baselineCounts = baseline.result.counts,
                baselineCounts.passed > 0
            else {
                throw LitmusFailure("unmutated suite did not pass with executed tests: \(baseline.result.reason)")
            }
            // The suite's own parallelism (child CPU ÷ wall, alone) bounds the workers: 7 copies of a suite that
            // already keeps 5 cores busy only queue for the same cores (fcheck pilot, 2026-11-02).
            let wall = max(Double(baseline.result.nanoseconds) / 1e9, 0.001)
            let parallelism = max(1, suiteCPU / wall)
            let workerCount = ChildUsage.workers(
                parallelism: parallelism,
                cores: ProcessInfo.processInfo.activeProcessorCount,
                limit: allowedWorkers
            )
            if workerCount < allowedWorkers {
                artifact.notes.append(
                    "workers reduced from \(allowedWorkers) to \(workerCount): the suite alone keeps "
                        + "\((parallelism * 10).rounded() / 10) cores busy"
                )
            }
            let derived = Int(baseline.result.nanoseconds * Int64(options.timeoutFactor) / 1_000_000_000) + 2
            let deadline = min(options.timeoutCap, max(options.minimumTimeout, derived))
            // Parallel workers slow every suite, so a first run gets twice the derived deadline; a rerun runs alone
            // with the same allowance, so contention can no longer cause its timeout.
            let rerunDeadline = min(2 * options.timeoutCap, 2 * deadline)
            let parallelDeadline = workerCount > 1 ? rerunDeadline : deadline
            artifact.policy = RunPolicy(
                harness: harness.kind,
                workers: workerCount,
                failFast: options.failFast,
                killConfirmation: options.killConfirmation,
                deadline: deadline,
                parallelDeadline: parallelDeadline,
                timeoutRerunDeadline: rerunDeadline,
                baselineNanoseconds: baseline.result.nanoseconds,
                suiteParallelism: (parallelism * 100).rounded() / 100
            )
            let judge = Judge(
                harness: harness,
                pool: pool,
                options: options,
                baseline: baselineCounts,
                deadline: deadline,
                parallelDeadline: parallelDeadline,
                rerunDeadline: rerunDeadline
            )

            var pending = Array(SchemaWriter.batches(plan.mutations, limit: options.batchSize).reversed())
            var buildIndex = 0
            while let group = pending.popLast() {
                try Task.checkCancellation()
                buildIndex += 1
                let name = "schema-\(buildIndex)"
                let installed = try install(group, in: snapshot)
                phase = clock.now
                let build = try await executor.execute(
                    driver.buildCommand(workspace: snapshot.root, artifacts: artifacts),
                    directory: snapshot.root,
                    environment: subjectEnvironment(nil),
                    timeout: options.buildTimeout
                )
                try writeLog(build, path: "\(logs)/\(name)-build.log")
                account("build", since: phase)
                guard build.exitStatus == 0, !build.timedOut else {
                    try installed.restore()
                    let diagnostics = CompilerDiagnostics(build, snapshotRoot: snapshot.root)
                    if build.timedOut {
                        for site in group {
                            try record(
                                site,
                                .infrastructureError,
                                "schema build timed out",
                                ["logs/\(name)-build.log"],
                                into: &artifact,
                                journal
                            )
                        }
                    } else if group.count == 1, let site = group.first {
                        // Unviable only when the compiler reports an error in the mutant's own file: this build changed
                        // nothing else. Flow errors ("missing return" after a negated `while true`) point at the end
                        // of the function, not at the mutant's lines. No error, or errors only elsewhere: not its doing.
                        let mutated = Set(installed.rendered.keys)
                        let own = diagnostics.errors.first { mutated.contains($0.path) }
                        let message = (own ?? diagnostics.errors.first)?.message ?? "no compiler diagnostic"
                        try record(
                            site,
                            own != nil ? .unviable : .infrastructureError,
                            own != nil ? "does not compile: \(message)" : "schema build failed elsewhere: \(message)",
                            ["logs/\(name)-build.log"],
                            into: &artifact,
                            journal
                        )
                    } else {
                        let suspects = Set(diagnostics.suspects(in: installed.rendered))
                        let named = group.filter { suspects.contains($0.id) }
                        if !named.isEmpty, named.count < group.count {
                            pending.append(named)
                            pending.append(group.filter { !suspects.contains($0.id) })
                        } else {
                            let middle = group.count / 2
                            pending.append(Array(group[middle...]))
                            pending.append(Array(group[..<middle]))
                        }
                    }
                    continue
                }

                phase = clock.now
                let control = try await judge.execute(name: "\(name)-control", activeID: "", deadline: deadline)
                guard control.result.outcome == .passed, control.result.counts == baselineCounts else {
                    for site in group {
                        try record(
                            site,
                            .infrastructureError,
                            "inactive schema control differs from the unmutated baseline: \(control.result.reason)",
                            control.result.evidence,
                            into: &artifact,
                            journal
                        )
                    }
                    try installed.restore()
                    account("tests", since: phase)
                    continue
                }
                for site in group where !control.reached.contains(site.id) {
                    try record(
                        site,
                        .noCoverage,
                        "no test reached the mutated code during the inactive control run",
                        control.result.evidence,
                        into: &artifact,
                        journal
                    )
                }
                let covered = group.filter { control.reached.contains($0.id) }
                let steps = try await mapConcurrently(covered, limit: workerCount) { site in try await judge.first(site)
                }
                var decisions: [Judge.Decision] = []
                for step in steps {
                    switch step {
                    case .done(let decision): decisions.append(decision)
                    case .rerun(let pending): decisions.append(try await judge.finish(pending))
                    }
                }
                for decision in decisions {
                    try record(
                        decision.site,
                        decision.verdict,
                        decision.reason,
                        decision.evidence,
                        nanoseconds: decision.nanoseconds,
                        tests: decision.tests,
                        into: &artifact,
                        journal
                    )
                }
                account("tests", since: phase)
                try installed.restore()
                try ArtifactCodec.write(artifact, path: checkpointPath)
            }
            artifact.complete = true
            timings["total"] = seconds(clock.now - started)
            artifact.timings = timings
            try ArtifactCodec.write(artifact, path: checkpointPath)
            try ArtifactCodec.write(artifact, path: output + "/run.pb")
            if !options.keepWorkspace {
                try fm.removeItem(atPath: snapshot.root)
                try fm.removeItem(atPath: workers)
            }
            return artifact
        } catch {
            artifact.notes.append("run stopped: \(error); partial evidence is not a successful run")
            timings["total"] = seconds(clock.now - started)
            artifact.timings = timings
            do { try ArtifactCodec.write(artifact, path: checkpointPath) } catch let writeError {
                throw LitmusFailure("execution failed: \(error); checkpoint failed: \(writeError)")
            }
            throw error
        }
    }

    private func record(
        _ site: Mutation,
        _ verdict: Verdict,
        _ reason: String,
        _ evidence: [String],
        nanoseconds: Int64 = 0,
        tests: TestCounts? = nil,
        into artifact: inout RunArtifact,
        _ journal: ResultJournal
    ) throws {
        let result = MutationResult(
            mutation: site,
            verdict: verdict,
            tests: tests,
            reason: reason,
            evidence: evidence,
            nanoseconds: nanoseconds
        )
        guard let index = artifact.results.firstIndex(where: { $0.mutation.id == site.id }) else {
            throw LitmusFailure("internal: result for unplanned mutant \(site.id)")
        }
        artifact.results[index] = result
        try journal.append(result)
    }

    /// The harness for this subject: Xcode for schemes, direct bundles when SwiftPM's layout is understood, else
    /// `swift test`. Every fallback is written to the run's notes.
    private func makeHarness(
        driver: BuildDriver,
        options: RunOptions,
        workspace: String,
        artifacts: String,
        logs: String,
        notes: inout [String]
    ) async throws -> any TestHarness {
        if driver.usesXcode {
            return XcodeHarness(
                executor: executor,
                driver: driver,
                workspace: workspace,
                artifacts: artifacts,
                logs: logs
            )
        }
        let fallback = SwiftPMToolHarness(
            executor: executor,
            driver: driver,
            workspace: workspace,
            artifacts: artifacts,
            logs: logs
        )
        guard options.harness == .automatic else { return fallback }
        func query(_ arguments: [String]) async throws -> String? {
            let output = try await executor.execute(
                ToolCommand(executable: "/usr/bin/xcrun", arguments: arguments),
                directory: workspace,
                environment: subjectEnvironment(nil),
                timeout: 120
            )
            guard output.exitStatus == 0, !output.truncated, !output.timedOut else { return nil }
            return String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let package = driver.swiftPMArguments(workspace: workspace, artifacts: artifacts)
        guard let binPath = try await query(["swift", "build", "--show-bin-path"] + package),
            let listing = try await query(["swift", "test", "list", "--skip-build"] + package),
            let xctest = try await query(["--find", "xctest"]),
            let swift = try await query(["--find", "swift"]),
            let platform = try await query(["--sdk", "macosx", "--show-sdk-platform-path"])
        else {
            notes.append("direct test bundles unavailable (toolchain query failed); using swift test, one worker")
            return fallback
        }
        let helper = URL(fileURLWithPath: swift).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("libexec/swift/pm/swiftpm-testing-helper").path
        guard FileManager.default.isExecutableFile(atPath: helper), xctest.hasPrefix("/"),
            let bundles = SwiftPMDirectHarness<Executor>.bundles(listing: listing, binPath: binPath)
        else {
            notes.append("direct test bundles unavailable (layout not understood); using swift test, one worker")
            return fallback
        }
        return SwiftPMDirectHarness(
            executor: executor,
            bundles: bundles,
            toolchain: .init(
                xctest: xctest,
                testingHelper: helper,
                frameworks: platform + "/Developer/Library/Frameworks",
                libraries: platform + "/Developer/usr/lib"
            ),
            workspace: workspace,
            logs: logs,
            workers: options.jobs
        )
    }

    /// Writes one batch's schemas into the snapshot, keeping the originals to restore.
    private func install(_ group: [Mutation], in snapshot: WorkspaceSnapshot) throws -> InstalledSchema {
        var originals: [String: Data] = [:]
        var rendered: [String: RenderedSchema] = [:]
        do {
            for (relative, sites) in Dictionary(grouping: group, by: \.path).sorted(by: { $0.key < $1.key }) {
                let path = try snapshot.path(for: relative)
                let bytes = try BoundedFileReader.read(path: path, cap: 2 << 20)
                guard let source = String(bytes: bytes, encoding: .utf8) else { throw LitmusFailure("not UTF-8") }
                let schema = try SchemaWriter.schema(source, mutations: sites)
                originals[path] = Data(bytes)
                try Data(schema.text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
                rendered[path] = schema
            }
        } catch {
            try InstalledSchema(originals: originals, rendered: rendered).restore()
            throw error
        }
        return InstalledSchema(originals: originals, rendered: rendered)
    }
}

/// The current schema files of a batch, by absolute snapshot path.
struct InstalledSchema {
    let originals: [String: Data]
    let rendered: [String: RenderedSchema]

    func restore() throws {
        for (path, data) in originals { try data.write(to: URL(fileURLWithPath: path), options: .atomic) }
    }
}

/// Compiler errors of a failed build, `path:line:column: error: message`, as swiftc and xcodebuild print them.
struct CompilerDiagnostics {
    struct Error {
        let path: String
        let line: Int
        let message: String
    }
    let errors: [Error]

    init(_ build: ProcessOutput, snapshotRoot: String) {
        var errors: [Error] = []
        let text = Self.plain(build.stdout + Array("\n".utf8) + build.stderr)
        for line in text.split(whereSeparator: \.isNewline) {
            guard let marker = line.range(of: ": error: ") else { continue }
            let location = line[..<marker.lowerBound].split(separator: ":")
            guard location.count >= 3, let number = Int(location[location.count - 2]) else { continue }
            let path = SourcePath.canonical(location.dropLast(2).joined(separator: ":"))
            guard path.hasPrefix(snapshotRoot + "/") else { continue }
            errors.append(Error(path: path, line: number, message: String(line[marker.upperBound...])))
        }
        self.errors = errors
    }

    /// `bytes` without terminal escape sequences: compilers colour their diagnostics (CSI `ESC [ … letter`) and link
    /// documentation (OSC `ESC ] … BEL` or `ESC ] … ESC \\`) even when the output is a pipe.
    static func plain(_ bytes: [UInt8]) -> String {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x1B, index + 1 < bytes.count else {
                output.append(bytes[index])
                index += 1
                continue
            }
            index += 1
            if bytes[index] == UInt8(ascii: "[") {
                index += 1
                while index < bytes.count, !(0x40...0x7E).contains(bytes[index]) { index += 1 }
                index += 1
            } else if bytes[index] == UInt8(ascii: "]") {
                while index < bytes.count, bytes[index] != 0x07,
                    !(bytes[index] == 0x1B && index + 1 < bytes.count && bytes[index + 1] == UInt8(ascii: "\\"))
                {
                    index += 1
                }
                index += bytes.indices.contains(index) && bytes[index] == 0x1B ? 2 : 1
            } else {
                index += 1
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// The mutants whose replacement covers a line an error points at.
    func suspects(in rendered: [String: RenderedSchema]) -> [String] {
        var ids: Set<String> = []
        for error in errors {
            guard let schema = rendered[error.path] else { continue }
            for (id, lines) in schema.lines where lines.contains(error.line) { ids.insert(id) }
        }
        return ids.sorted()
    }
}

/// Runs and classifies mutants against the current build.
struct Judge: Sendable {
    let harness: any TestHarness
    let pool: ResourcePool<WorkerSlot>
    let options: RunOptions
    let baseline: TestCounts
    let deadline: Int
    /// The deadline of a mutant's first run among parallel workers: contention slows every suite.
    let parallelDeadline: Int
    let rerunDeadline: Int

    struct Execution {
        let result: TestRunResult
        let reached: Set<String>
    }

    struct Decision: Sendable {
        let site: Mutation
        let verdict: Verdict
        let reason: String
        let evidence: [String]
        let nanoseconds: Int64
        let tests: TestCounts?
    }

    /// One suite execution on a free worker, with fresh marker and temporary directories.
    func execute(
        name: String,
        activeID: String,
        deadline: Int,
        failFast: Bool = false,
        only: [String]? = nil
    ) async throws -> Execution {
        guard let slot = pool.checkout() else { throw LitmusFailure("internal: no free worker") }
        defer { pool.checkin(slot) }
        let unique = UUID().uuidString.prefix(8)
        let coverage = "\(slot.directory)/coverage-\(unique)", temporary = "\(slot.directory)/tmp-\(unique)"
        for directory in [coverage, temporary] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        defer {
            try? FileManager.default.removeItem(atPath: coverage)
            try? FileManager.default.removeItem(atPath: temporary)
        }
        var request = TestRunRequest(
            name: name,
            activeID: activeID,
            coverageDirectory: coverage,
            temporaryDirectory: temporary,
            deadline: deadline,
            failFast: failFast
        )
        request.onlySwiftTesting = only
        let result = try await harness.run(request)
        return Execution(result: result, reached: ActivationEnvironment.reached(in: coverage))
    }

    /// What a mutant's first, parallel run decided, or the rerun it needs.
    enum Step: Sendable {
        case done(Decision)
        /// A failure without activation, a crash, a timeout, or a kill to confirm: rerun after the parallel pass, alone.
        case rerun(Pending)
    }

    struct Pending: Sendable {
        let site: Mutation
        let outcome: TestRunOutcome
        let activated: Bool
        let failingTests: [String]
        let evidence: [String]
        let nanoseconds: Int64
    }

    /// Accumulates the evidence and time of one mutant's runs.
    private struct Ledger {
        let site: Mutation
        let baseline: TestCounts
        var evidence: [String]
        var nanoseconds: Int64

        func decision(_ verdict: Verdict, _ reason: String, _ tests: TestCounts? = nil) -> Decision {
            Decision(
                site: site,
                verdict: verdict,
                reason: reason,
                evidence: evidence,
                nanoseconds: nanoseconds,
                tests: tests
            )
        }

        func passing(_ execution: Execution) -> Decision {
            guard let counts = execution.result.counts, counts.passed == baseline.passed, counts.total == baseline.total
            else {
                return decision(.infrastructureError, "the passing run's test population differs from the baseline")
            }
            return execution.reached.contains(site.id)
                ? decision(.survived, "every test passed after the mutated code ran", counts)
                : decision(.noCoverage, "the control reached the mutated code, the active run did not", counts)
        }
    }

    private func run(
        _ site: Mutation,
        _ suffix: String,
        active: Bool,
        deadline: Int,
        only: [String]? = nil,
        ledger: inout Ledger
    ) async throws -> Execution {
        let execution = try await execute(
            name: "mutant-\(site.id)\(suffix)",
            activeID: active ? site.id : "",
            deadline: deadline,
            failFast: active && options.failFast,
            only: only
        )
        ledger.evidence += execution.result.evidence
        ledger.nanoseconds += execution.result.nanoseconds
        return execution
    }

    /// The first run of one reached mutant, among the parallel workers, with `parallelDeadline`.
    func first(_ site: Mutation) async throws -> Step {
        var ledger = Ledger(site: site, baseline: baseline, evidence: [], nanoseconds: 0)
        let first = try await run(site, "", active: true, deadline: parallelDeadline, ledger: &ledger)
        let activated = first.reached.contains(site.id)
        switch first.result.outcome {
        case .passed: return .done(ledger.passing(first))
        case .unusable: return .done(ledger.decision(.infrastructureError, first.result.reason))
        case .failed where activated && options.killConfirmation == .none:
            return .done(ledger.decision(.killed, first.result.reason, first.result.counts))
        case .failed, .crashed, .timedOut:
            return .rerun(
                Pending(
                    site: site,
                    outcome: first.result.outcome,
                    activated: activated,
                    failingTests: first.result.failingTests,
                    evidence: ledger.evidence,
                    nanoseconds: ledger.nanoseconds
                )
            )
        }
    }

    /// The rerun a first run asked for, alone on the machine, with `rerunDeadline`.
    func finish(_ pending: Pending) async throws -> Decision {
        let site = pending.site
        var ledger = Ledger(
            site: site,
            baseline: baseline,
            evidence: pending.evidence,
            nanoseconds: pending.nanoseconds
        )
        if pending.outcome == .failed, pending.activated, options.killConfirmation == .full {
            let control = try await run(site, "-control", active: false, deadline: rerunDeadline, ledger: &ledger)
            let again = try await run(site, "-confirm", active: true, deadline: rerunDeadline, ledger: &ledger)
            guard control.result.outcome == .passed, control.result.counts == baseline,
                again.result.outcome == .failed, again.reached.contains(site.id)
            else {
                return ledger.decision(.infrastructureError, "kill not reproduced around a passing inactive control")
            }
            return ledger.decision(.killed, "two failing active runs around a passing inactive control")
        }
        if pending.outcome == .failed, pending.activated, harness.selectsTests, !pending.failingTests.isEmpty {
            // The failing tests alone: they must fail with the mutant and reach it, and pass without it.
            let tests = pending.failingTests
            let active = try await run(
                site,
                "-confirm",
                active: true,
                deadline: rerunDeadline,
                only: tests,
                ledger: &ledger
            )
            if active.result.outcome == .failed, active.reached.contains(site.id) {
                let control = try await run(
                    site,
                    "-control",
                    active: false,
                    deadline: rerunDeadline,
                    only: tests,
                    ledger: &ledger
                )
                guard control.result.outcome == .passed else {
                    return ledger.decision(
                        .infrastructureError,
                        "the failing tests also fail without the mutant: \(tests.joined(separator: ", "))"
                    )
                }
                let killers = active.result.failingTests.isEmpty ? tests : active.result.failingTests
                return ledger.decision(.killed, "killed by \(killers.joined(separator: ", ")), confirmed alone")
            }
            // Not reproduced by the failing tests alone, or they do not reach the mutant: the first failure was not
            // the mutant's doing. The whole suite, alone, decides.
        }
        let again = try await run(site, "-rerun", active: true, deadline: rerunDeadline, ledger: &ledger)
        let reached = again.reached.contains(site.id)
        switch (pending.outcome, again.result.outcome) {
        case (_, .failed) where reached: return ledger.decision(.killed, again.result.reason, again.result.counts)
        case (.crashed, .crashed) where reached:
            return ledger.decision(.crashed, "crashed twice after the mutated code ran")
        case (.timedOut, .crashed) where reached: return ledger.decision(.crashed, "crashed when rerun alone")
        case (.timedOut, .timedOut) where reached:
            return ledger.decision(.timeout, "did not finish in \(rerunDeadline) s when rerun alone")
        case (_, .passed): return ledger.passing(again)
        default:
            return ledger.decision(
                .infrastructureError,
                "first run \(pending.outcome.rawValue) (activated: \(pending.activated)), rerun alone "
                    + "\(again.result.outcome.rawValue) (activated: \(reached))"
            )
        }
    }
}

func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

/// The tool's version, written to provenance and reports.
public enum LitmusVersion {
    public static let current = "0.2.0-dev"
}
