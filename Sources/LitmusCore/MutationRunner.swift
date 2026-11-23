internal import AemiIO
internal import AemiJSON
internal import AemiRuntime
internal import Foundation
internal import ProjectModel
internal import SourceCorpus

/// A worker's private directory, from aemi's `ResourcePool`: markers and `TMPDIR` of the runs it hosts live under it.
struct WorkerSlot: Sendable {
    let directory: String

    /// The directory of worker `index` under `root`, created.
    init(root: String, index: Int) throws {
        directory = root + "/worker-\(index)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
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
    let executor: Executor
    public init(executor: Executor) { self.executor = executor }

    /// Creates an owned snapshot, reuses what cannot have changed, validates the baseline, then decides every site
    /// the budget allows.
    /// - Important: Only run on trusted project code; copying is not a security sandbox.
    /// - Throws: On baseline failure, cancellation or artifact/I/O failure; the checkpoint and the journal keep the
    ///   decisions made so far.
    public func run(driver: BuildDriver, outputDirectory: String, options: RunOptions = RunOptions()) async throws
        -> RunArtifact
    {
        try await RunSession(
            runner: self,
            executor: executor,
            driver: driver,
            outputDirectory: outputDirectory,
            options: options
        ).run()
    }

    /// What one baseline established: the judge, its counts and deadlines, and the baseline execution itself (the
    /// control of the first schema when that schema was the baseline).
    struct Established {
        let judge: Judge
        let counts: TestCounts
        let deadline: Int
        let workerCount: Int
        let testFunctions: [String]
        let baseline: Judge.Execution
    }

    /// Where a decision goes: the run's journal, and the result store when there is one.
    struct Sink {
        let journal: ResultJournal
        let store: ResultStore?
        let runID: String
        var progress: ProgressReporter? = nil
    }

    /// The resolved verdicts of an earlier run (`--resume`), by reuse key: its checkpoint, then its journal (later
    /// decisions win; a frame cut short by a crash is ignored). Evidence paths are made absolute to that run.
    static func previousResults(runDirectory: String) throws -> [String: ReusedResult] {
        let directory = SourcePath.canonical(runDirectory)
        let artifact = try ArtifactCodec.read(RunArtifact.self, path: directory + "/run.json")
        var results = artifact.results
        let journalPath = directory + "/results.journal"
        if FileManager.default.fileExists(atPath: journalPath) {
            results += try ResultJournal.read(path: journalPath).results
        }
        var byKey: [String: ReusedResult] = [:]
        for var result in results {
            guard let key = result.reuseKey, result.verdict.isResolved else { continue }
            if result.reusedFrom == nil {
                result = MutationResult(
                    mutation: result.mutation,
                    verdict: result.verdict,
                    tests: result.tests,
                    reason: result.reason,
                    evidence: result.evidence.map { $0.hasPrefix("/") ? $0 : directory + "/" + $0 },
                    nanoseconds: result.nanoseconds
                )
            }
            byKey[key] = ReusedResult(result: result, runID: artifact.provenance.runID)
        }
        return byKey
    }

    /// How long each mutant took in an earlier run (`run.json` and its journal), by mutation id: ids are anchored to
    /// the code, so they outlive the edits that change a verdict's reuse key.
    static func previousDurations(runDirectory: String) -> [String: Int64] {
        let directory = SourcePath.canonical(runDirectory)
        var results = (try? ArtifactCodec.read(RunArtifact.self, path: directory + "/run.json"))?.results ?? []
        if let journal = try? ResultJournal.read(path: directory + "/results.journal") { results += journal.results }
        var durations: [String: Int64] = [:]
        for result in results where result.nanoseconds > 0 { durations[result.mutation.id] = result.nanoseconds }
        return durations
    }

    /// Records `sites` as not run within the budget.
    func untested(
        _ sites: [Mutation],
        _ reason: String,
        stoppedBy: String,
        into artifact: inout RunArtifact,
        _ sink: Sink
    ) throws {
        guard !sites.isEmpty else { return }
        for site in sites { try record(site, .notRun, reason, [], into: &artifact, sink) }
        var budget = artifact.budget ?? BudgetRecord()
        budget.stoppedBy = budget.stoppedBy ?? stoppedBy
        budget.untested += sites.map(\.id)
        artifact.budget = budget
    }

    /// For each mutant, the test modules that can reach its file: the test targets analyzerkit finds from the
    /// manifests (`ProjectClassification.testTargets(covering:)`), as module names, among `modules`
    /// (those the suite has). A mutant whose file no target claims, or whose targets are not among them, is left out:
    /// it runs every module.
    static func coveringModules(_ mutations: [Mutation], root: String, modules: Set<String>) -> [String: Set<String>] {
        guard !modules.isEmpty, let layout = ProjectLayout.discover(paths: [root]) else { return [:] }
        let classification = ProjectClassification.load(layout)
        var byPath: [String: Set<String>?] = [:]
        var covering: [String: Set<String>] = [:]
        for mutation in mutations {
            if byPath[mutation.path] == nil {
                let targets = classification.testTargets(covering: SourcePath.canonical(root + "/" + mutation.path))
                // SwiftPM spells a module with `_` for spaces and dashes; Xcode's result bundles keep the target name.
                let names = Set(targets.flatMap { [moduleName($0.name), $0.name] }).intersection(modules)
                byPath[mutation.path] = .some(names.isEmpty ? nil : names)
            }
            if let names = byPath[mutation.path] ?? nil { covering[mutation.id] = names }
        }
        return covering
    }

    /// SwiftPM's module name for a target: every character outside `[A-Za-z0-9_]` becomes `_`, and a leading digit
    /// gets one before it.
    static func moduleName(_ target: String) -> String {
        var name = String(target.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") ? $0 : "_" })
        if let first = name.first, first.isNumber { name = "_" + name }
        return name
    }

    /// The test functions (not suites) declared in the Swift Testing event streams among `evidence`, identifiers
    /// without their source location, sorted.
    static func testFunctions(in evidence: [String], logs root: String) -> [String] {
        var tests: Set<String> = []
        for path in evidence where path.hasSuffix(".events.jsonl") {
            guard let bytes = try? BoundedFileReader.read(path: root + "/" + path, cap: 64 << 20) else { continue }
            for line in bytes.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
                guard let document = try? AemiJSON.parse(Array(line)) else { continue }
                let root = document.root
                guard root.kind.string == "test", root.payload.kind.string == "function",
                    let id = root.payload.id.string
                else { continue }
                tests.insert(testName(id))
            }
        }
        return tests.sorted()
    }

    /// Removes `directory`, retrying while another process adds to it; true when it is gone.
    static func remove(_ directory: String) -> Bool {
        for attempt in 0..<5 {
            if (try? FileManager.default.removeItem(atPath: directory)) != nil
                || !FileManager.default.fileExists(atPath: directory)
            {
                return true
            }
            usleep(UInt32(100_000 << attempt))
        }
        return false
    }

    func record(_ decision: Judge.Decision, into artifact: inout RunArtifact, _ sink: Sink) throws {
        try record(
            decision.site,
            decision.verdict,
            decision.reason,
            decision.evidence,
            nanoseconds: decision.nanoseconds,
            tests: decision.tests,
            into: &artifact,
            sink
        )
    }

    func record(
        _ site: Mutation,
        _ verdict: Verdict,
        _ reason: String,
        _ evidence: [String],
        nanoseconds: Int64 = 0,
        tests: TestCounts? = nil,
        into artifact: inout RunArtifact,
        _ sink: Sink
    ) throws {
        try record(
            MutationResult(
                mutation: site,
                verdict: verdict,
                tests: tests,
                reason: reason,
                evidence: evidence,
                nanoseconds: nanoseconds
            ),
            into: &artifact,
            sink
        )
    }

    /// Replaces the planned mutant's result, journals it, and stores it when it was decided now and resolved.
    func record(_ result: MutationResult, into artifact: inout RunArtifact, _ sink: Sink) throws {
        guard let index = artifact.results.firstIndex(where: { $0.mutation.id == result.mutation.id }) else {
            throw LitmusFailure("internal: result for unplanned mutant \(result.mutation.id)")
        }
        var result = result
        result.reuseKey = artifact.results[index].reuseKey
        artifact.results[index] = result
        try sink.journal.append(result)
        sink.progress?.report(result)
        if let store = sink.store, let key = result.reuseKey, result.reusedFrom == nil {
            // A cache: a record that cannot be written is a later miss, never a failed run.
            do { try store.put(key, result, runID: sink.runID) } catch {
                artifact.notes.append("result store: \(result.mutation.id) not stored: \(error)")
            }
        }
    }

    /// The harness for this subject: Xcode for schemes, direct bundles when SwiftPM's layout is understood, else
    /// `swift test`. Every fallback is written to the run's notes.
    func makeHarness(
        driver: BuildDriver,
        options: RunOptions,
        workspace: String,
        artifacts: String,
        logs: String,
        fleet: SimulatorFleet? = nil,
        notes: inout [String]
    ) async throws -> any TestHarness {
        if driver.usesXcode {
            try XcodeTestConfiguration.validateArtifacts(artifacts: artifacts, driver: driver)
            let xcode = XcodeHarness(
                executor: executor,
                driver: driver,
                workspace: workspace,
                artifacts: artifacts,
                logs: logs,
                fleet: fleet,
                keepResultBundles: options.keepResultBundles
            )
            guard options.simulatorHarness, let destination = driver.destination,
                let udid = SimulatorDirectHarness<Executor>.simulatorID(destination)
            else { return xcode }
            guard !driver.xcodebuildArgumentsSelectTests else {
                notes.append(
                    "simulator helper not used: --xcodebuild-argument selects tests (-only-testing, -skip-testing or test configurations), which only xcodebuild honours"
                )
                return xcode
            }
            do {
                return try await simulatorHarness(
                    udid: udid,
                    fleet: fleet ?? .single(udid: udid, directory: workspace),
                    workspace: driver.executionDirectory(workspace: workspace),
                    artifacts: artifacts,
                    logs: logs,
                    notes: &notes
                ) ?? xcode
            } catch {
                notes.append("simulator helper unavailable (\(error)); using xcodebuild")
                return xcode
            }
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
                directory: driver.executionDirectory(workspace: workspace),
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
            workspace: driver.executionDirectory(workspace: workspace),
            logs: logs,
            workers: options.jobs
        )
    }

    /// Writes one batch's schemas into the snapshot, keeping the originals to restore.
    /// The direct simulator harness when every test target is hostless and the helper runs on the booted simulator
    ///; nil, with a note, to use `xcodebuild`.
    func simulatorHarness(
        udid: String,
        fleet: SimulatorFleet,
        workspace: String,
        artifacts: String,
        logs: String,
        notes: inout [String]
    ) async throws -> (any TestHarness)? {
        let products = artifacts + "/DerivedData/Build/Products"
        let runs = try FileManager.default.contentsOfDirectory(atPath: products).filter { $0.hasSuffix(".xctestrun") }
        guard runs.count == 1, let run = runs.first else {
            notes.append("simulator helper not used: \(runs.count) .xctestrun files; using xcodebuild")
            return nil
        }
        let helper = try await SimulatorHelper.build(into: artifacts, executor: executor, logs: logs)
        let targets = try XCTestRunTarget.targets(
            xctestrun: products + "/" + run,
            products: products,
            platforms: helper.platforms
        )
        guard let bundles = SimulatorDirectHarness<Executor>.bundles(targets) else {
            notes.append("simulator helper not used: a test target is hosted by an application or is a UI test")
            return nil
        }
        // `simctl spawn` needs a booted device; xcodebuild boots it itself.
        let boot = try await executor.execute(
            ToolCommand(executable: "/usr/bin/xcrun", arguments: ["simctl", "bootstatus", udid, "-b"]),
            directory: workspace,
            environment: subjectEnvironment(nil),
            timeout: 600
        )
        guard boot.exitStatus == 0 else {
            notes.append("simulator helper not used: \(udid) did not boot; using xcodebuild")
            return nil
        }
        let direct = SimulatorDirectHarness(
            executor: executor,
            fleet: fleet,
            bundles: bundles,
            helper: helper,
            workspace: workspace,
            logs: logs
        )
        guard try await direct.probe() else {
            notes.append("simulator helper not used: its probe failed (logs/simulator-probe.log); using xcodebuild")
            return nil
        }
        notes.append(
            "hostless test bundles run on simulator \(udid) through Litmus's helper: \(bundles.map(\.module).joined(separator: ", "))"
        )
        return direct
    }

    /// In place, each original is made recoverable through `journal` before its file is rewritten.
    func install(_ group: [Mutation], in snapshot: WorkspaceSnapshot, journal: InPlaceJournal?) throws
        -> InstalledSchema
    {
        var originals: [String: Data] = [:]
        var rendered: [String: RenderedSchema] = [:]
        do {
            for (relative, sites) in Dictionary(grouping: group, by: \.path).sorted(by: { $0.key < $1.key }) {
                let path = try snapshot.path(for: relative)
                let bytes = try BoundedFileReader.read(path: path, cap: 2 << 20)
                guard let source = String(bytes: bytes, encoding: .utf8) else { throw LitmusFailure("not UTF-8") }
                let schema = try SchemaWriter.schema(source, mutations: sites)
                originals[path] = Data(bytes)
                if let journal {
                    try journal.rewrite(path, original: bytes, schema: Array(schema.text.utf8))
                } else {
                    // Scratch files the next run re-creates: atomic, not synced.
                    try AtomicFile.replace(at: path, with: Array(schema.text.utf8), durability: .none)
                }
                rendered[path] = schema
            }
        } catch {
            try InstalledSchema(originals: originals, rendered: rendered, journal: journal).restore()
            throw error
        }
        return InstalledSchema(originals: originals, rendered: rendered, journal: journal)
    }

    /// Refuses an in-place run when a file to mutate is untracked or modified in git: then `git checkout` could not be
    /// the last resort that restores it.
    func requireCleanGit(_ paths: [String], root: String) async throws {
        func git(_ arguments: [String]) async throws -> ProcessOutput {
            try await executor.execute(
                ToolCommand(executable: "/usr/bin/xcrun", arguments: ["git"] + arguments),
                directory: root,
                environment: subjectEnvironment(nil),
                timeout: 120
            )
        }
        let tracked = try await git(["ls-files", "--error-unmatch", "--"] + paths)
        guard tracked.exitStatus == 0 else {
            throw LitmusFailure("--workspace in-place needs a git work tree whose files to mutate are all tracked")
        }
        let status = try await git(["status", "--porcelain=v1", "--"] + paths)
        guard status.exitStatus == 0, !status.truncated, status.stdout.isEmpty else {
            let changed = String(decoding: status.stdout.prefix(400), as: UTF8.self)
            throw LitmusFailure(
                "--workspace in-place needs the files to mutate unmodified (commit or stash first): \(changed)"
            )
        }
    }
}

func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

/// The tool's version, written to provenance and reports.
public enum LitmusVersion {
    public static let current = "0.3.2"
}
