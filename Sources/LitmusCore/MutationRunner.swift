internal import AemiIO
internal import AemiJSON
internal import AemiRuntime
internal import Foundation
internal import ProjectModel
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
    /// When not empty, only files matching these substrings or globs are mutated.
    public var include: [String] = []
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
    /// The most memory one test process and what it starts may use, in MiB; past it the run is stopped and counts as
    /// a crash (a mutant that allocates without bound). 0: no limit.
    public var memoryLimitMiB = 4096
    /// Run builds and first runs at background priority, to leave a shared machine usable. Reruns, which decide
    /// timeouts, run at the normal priority: background stretches wall time 2 to 15 times (measured).
    public var background = false
    /// Runs of the unmutated suite looking for flaky Swift Testing tests (`--repetitions`); a test that fails in any is
    /// left out of every later run. 1: no probe.
    public var baselineRepetitions = 3
    /// The most Swift Testing tests one suite runs at once; workers are then sized from it. Nil: the suite decides.
    public var suiteWidth: Int?
    /// Run, for each mutant, only the test targets that can reach its file (from the manifests, without building).
    public var selectTestTargets = true
    /// After each schema's control run, run every Swift Testing test alone, no mutant active, and record which tests
    /// reach which mutants (`RunArtifact.perTestReach`): the data per-test selection would use. Costs one run per test
    /// and schema build.
    public var perTestReach = false
    /// The change a pull-request run is limited to (`--diff`, `--diff-base`); nil mutates the whole subject.
    public var scope: ChangeScope?
    /// Stop starting schema builds and first runs after this many seconds; what did not run is reported as such.
    public var budgetSeconds: Int?
    /// Run at most this many mutants (in plan order: changed lines first); the rest are reported as not run.
    public var maxMutants: Int?
    /// The first schema that builds is the baseline (its inactive run); false builds and tests the unmutated subject
    /// first, as before 0.3 (`--unmutated-baseline`).
    public var inactiveSchemaBaseline = true
    /// A result store directory: verdicts are looked up before running and stored as decided.
    public var resultStore: String?
    public var storeReadOnly = false
    public var storeLimitMiB = 1024
    /// How reuse keys cover the code (`--reuse`); `.declaration` only for nightly runs.
    public var reuseMode = ReuseContext.Mode.closure
    /// An earlier run directory whose decided verdicts are reused when their keys match (`--resume`).
    public var resume: String?
    /// Where the run builds and mutates (`--workspace`).
    public var workspace = WorkspaceStrategy.copy
    /// The directory holding Xcode's `DerivedData` (`--build-directory`); default: the run's or the persistent one.
    public var buildDirectory: String?

    public init() {}

    /// The supervision every test and build process gets.
    func supervision(background: Bool? = nil) -> Supervision {
        var supervision = Supervision()
        supervision.memoryLimitBytes = memoryLimitMiB > 0 ? UInt64(memoryLimitMiB) << 20 : nil
        supervision.sampling = memoryLimitMiB > 0 ? .milliseconds(100) : nil
        supervision.background = background ?? self.background
        return supervision
    }

    func validate() throws {
        guard (1...256).contains(batchSize), (1...86_400).contains(buildTimeout), (1...86_400).contains(timeoutCap),
            (1...100).contains(timeoutFactor), (1...86_400).contains(minimumTimeout), minimumTimeout <= timeoutCap,
            (1...256).contains(jobs), (0...1_048_576).contains(memoryLimitMiB), (1...100).contains(baselineRepetitions),
            suiteWidth.map({ (1...256).contains($0) }) ?? true,
            budgetSeconds.map({ (1...604_800).contains($0) }) ?? true, maxMutants.map({ $0 >= 1 }) ?? true,
            (1...1_048_576).contains(storeLimitMiB)
        else {
            throw LitmusFailure(
                "batch size, deadlines, jobs, memory, repetitions, width, budget or store limit outside documented bounds"
            )
        }
    }
}

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
    private let executor: Executor
    public init(executor: Executor) { self.executor = executor }

    /// Creates an owned snapshot, reuses what cannot have changed, validates the baseline, then decides every site
    /// the budget allows.
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
        let logs = output + "/logs", workers = output + "/workers"
        for directory in [output, logs, workers] {
            try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        var timings: [String: Double] = [:]
        func account(_ phase: String, since start: ContinuousClock.Instant) {
            timings[phase, default: 0] += seconds(clock.now - start)
        }
        let counter = RunCounter()
        /// The run's cost now; disk measured before the workspace is removed.
        func cost(workspace: String?) -> RunCost {
            var cost = RunCost()
            cost.sample()
            cost.wallSeconds = RunCost.rounded(seconds(clock.now - started))
            cost.runDirectoryMiB = RunCost.diskMiB(output)
            cost.workspaceMiB = workspace.map(RunCost.diskMiB) ?? 0
            cost.builds = counter.builds
            cost.testRuns = counter.tests
            return cost
        }
        /// No new schema build or first run starts past it (`--budget`).
        let budgetEnd = options.budgetSeconds.map { started + .seconds($0) }

        var phase = clock.now
        if let scope = options.scope {
            // The fast path: a change reaching no site ends here, before any copy, build or toolchain query.
            let sourcePlan = try await MutationPlanner.plan(
                root: root,
                exclude: options.exclude,
                include: options.include,
                jobs: 8,
                scope: scope
            )
            account("plan", since: phase)
            if sourcePlan.mutations.isEmpty {
                phase = clock.now
                let inputs = try await WorkspaceSnapshot.currentEntries(root)
                account("inventory", since: phase)
                let provenance = RunProvenance(
                    toolVersion: LitmusVersion.current,
                    snapshotSHA256: Digest.sha256(try ArtifactCodec.json(inputs)),
                    inputs: inputs,
                    driver: driver,
                    toolchain: "not invoked: the change reaches no mutable site",
                    startedAt: ISO8601DateFormatter().string(from: Date()),
                    executionPolicy: RunArtifact.executionPolicy
                )
                var artifact = RunArtifact(provenance: provenance, plan: sourcePlan)
                artifact.notes.append(
                    "\(scope.source): \(sourcePlan.scope?.swiftFiles ?? 0) changed Swift file(s), no mutable site on "
                        + (scope.breadth == .lines ? "their changed lines" : "them")
                        + "; nothing was copied, built or run"
                )
                artifact.complete = true
                timings["total"] = seconds(clock.now - started)
                artifact.timings = timings
                artifact.cost = cost(workspace: nil)
                try ArtifactCodec.write(artifact, path: output + "/run.json")
                try ArtifactCodec.write(artifact, path: output + "/run.pb")
                return artifact
            }
            phase = clock.now
        }
        let prepared = try await PreparedWorkspace.prepare(
            options.workspace,
            source: root,
            output: output,
            buildDirectory: options.buildDirectory.map(SourcePath.canonical)
        )
        let snapshot = prepared.snapshot
        let artifacts = prepared.buildDirectory
        try fm.createDirectory(atPath: artifacts, withIntermediateDirectories: true)
        /// Ends the workspace: restores what is still rewritten (in place), releases the lock.
        func releaseWorkspace() {
            if let journal = prepared.restore {
                _ = try? journal.restoreAll()
                prepared.lock?.release()
                journal.tidy()
            } else {
                prepared.lock?.release()
            }
        }
        account("snapshot", since: phase)
        phase = clock.now
        let clonePlan = try await MutationPlanner.plan(
            root: snapshot.root,
            exclude: options.exclude,
            include: options.include,
            jobs: 8,
            scope: options.scope
        )
        account("plan", since: phase)
        var plan = MutationPlan(
            root: root,
            analyzedFiles: clonePlan.analyzedFiles,
            mutations: clonePlan.mutations,
            suppressed: clonePlan.suppressed,
            notes: clonePlan.notes
        )
        plan.scope = clonePlan.scope
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
        for link in snapshot.skippedLinks {
            artifact.notes.append("symbolic link left out of the workspace (never followed): \(link)")
        }
        artifact.notes += prepared.notes
        if prepared.restore != nil {
            // In place: every file to mutate must be tracked and unmodified, so git can restore it as a last resort.
            try await requireCleanGit(Set(plan.mutations.map(\.path)).sorted(), root: root)
            artifact.notes.append(
                "in place: the subject root is the workspace; originals are backed up in .litmus/restore before each "
                    + "rewrite and restored after each batch"
            )
        }

        // Reuse (ADR 0007): every result carries its key, so any run can be resumed or seed a store; a verdict is
        // reused only when its key matches, and says where it came from.
        phase = clock.now
        let reuse = try ReuseContext(
            mode: options.reuseMode,
            root: snapshot.root,
            entries: snapshot.entries,
            wholeSnapshot: snapshot.digest,
            mutations: plan.mutations,
            closureKnown: driver.container == nil,
            context: ReuseContextInputs(
                toolVersion: LitmusVersion.current,
                executionPolicy: RunArtifact.executionPolicy,
                toolchain: provenance.toolchain,
                driver: driver,
                harness: options.harness.rawValue,
                failFast: options.failFast,
                killConfirmation: options.killConfirmation.rawValue,
                memoryLimitMiB: options.memoryLimitMiB,
                timeoutCap: options.timeoutCap,
                timeoutFactor: options.timeoutFactor,
                minimumTimeout: options.minimumTimeout,
                baselineRepetitions: options.baselineRepetitions,
                suiteWidth: options.suiteWidth,
                selectTestTargets: options.selectTestTargets,
                background: options.background,
                excluded: options.exclude.sorted()
            )
        )
        for index in artifact.results.indices {
            artifact.results[index].reuseKey = reuse.key(artifact.results[index].mutation)
        }
        let store = try options.resultStore.map {
            try ResultStore(
                directory: $0,
                readOnly: options.storeReadOnly,
                limitMiB: options.storeLimitMiB,
                forbidden: root,
                secret: ProcessInfo.processInfo.environment["LITMUS_STORE_KEY"]
            )
        }
        let previous = try options.resume.map { try Self.previousResults(runDirectory: $0) } ?? [:]
        let checkpointPath = output + "/run.json"
        try ArtifactCodec.write(artifact, path: checkpointPath)
        let sink = Sink(
            journal: try ResultJournal(path: output + "/results.journal"),
            store: store,
            runID: provenance.runID
        )
        var reused: (resumed: Int, stored: Int) = (0, 0)
        for mutation in plan.mutations {
            guard let key = artifact.results.first(where: { $0.mutation.id == mutation.id })?.reuseKey else { continue }
            let resumed = previous[key]
            guard let hit = resumed ?? store?.lookup(key, mutation: mutation) else { continue }
            var result = MutationResult(
                mutation: mutation,
                verdict: hit.result.verdict,
                tests: hit.result.tests,
                reason: hit.result.reason,
                evidence: resumed != nil ? hit.result.evidence : [],
                nanoseconds: hit.result.nanoseconds
            )
            result.reusedFrom = hit.result.reusedFrom ?? (hit.runID + (reuse.mode == .closure ? "" : " (declaration)"))
            try record(result, into: &artifact, sink)
            if resumed != nil { reused.resumed += 1 } else { reused.stored += 1 }
        }
        artifact.reuse = ReuseRecord(
            mode: reuse.mode,
            context: reuse.context,
            store: store?.directory,
            storeReadOnly: store?.readOnly,
            resumedFrom: options.resume,
            resumed: reused.resumed,
            fromStore: reused.stored
        )
        if reused.resumed + reused.stored > 0 {
            artifact.notes.append(
                "\(reused.resumed + reused.stored) verdict(s) reused (\(reused.resumed) resumed, \(reused.stored) "
                    + "from the store), each labelled with the run that decided it; key mode \(reuse.mode.rawValue)"
            )
        }
        account("reuse", since: phase)

        // What runs: the mutants without a reused verdict, in plan order (changed lines first), within the budget.
        let decided = Set(artifact.results.filter { $0.reusedFrom != nil }.map(\.mutation.id))
        var toRun = plan.mutations.filter { !decided.contains($0.id) }
        if options.budgetSeconds != nil || options.maxMutants != nil {
            artifact.budget = BudgetRecord(seconds: options.budgetSeconds, maxMutants: options.maxMutants)
        }
        if let limit = options.maxMutants, toRun.count > limit {
            let over = Array(toRun[limit...])
            toRun = Array(toRun[..<limit])
            try untested(over, "beyond --max-mutants \(limit)", stoppedBy: "max-mutants", into: &artifact, sink)
        }

        // Builds run at the run's priority, without the memory limit: a compiler may use more than a test should.
        var buildSupervision = Supervision()
        buildSupervision.background = options.background
        /// Ends the run: complete, timed, costed, the workspace removed unless kept.
        func finish() throws -> RunArtifact {
            artifact.complete = true
            if let store {
                let removed = store.evict()
                artifact.notes += store.notes
                if removed > 0 {
                    artifact.notes.append("result store: \(removed) least recently used record(s) evicted")
                }
            }
            timings["total"] = seconds(clock.now - started)
            artifact.timings = timings
            artifact.cost = cost(workspace: prepared.removable ? snapshot.root : nil)
            if let journal = prepared.restore {
                // In place: nothing may stay rewritten, and every mutated file must hold its original bytes again.
                try journal.restoreAll()
                let mutated = Set(plan.mutations.map(\.path))
                let expected = Dictionary(
                    snapshot.entries.map { ($0.path, $0.sha256) },
                    uniquingKeysWith: { a, _ in a }
                )
                for path in mutated.sorted() {
                    let bytes = try BoundedFileReader.read(path: root + "/" + path, cap: 64 << 20)
                    guard Digest.sha256(bytes) == expected[path] else {
                        throw LitmusFailure("in place: \(path) does not hold its original bytes after the run")
                    }
                }
                artifact.notes.append("in place: \(mutated.count) mutated file(s) restored and verified")
            }
            releaseWorkspace()
            if !options.keepWorkspace {
                // Every verdict is recorded: a workspace that cannot be removed (Finder or Spotlight writing into it
                // while it goes, seen 2026-11-02) is noted, never a failed run.
                for directory in (prepared.removable ? [snapshot.root] : []) + [workers]
                where !Self.remove(directory) {
                    artifact.notes.append("could not remove \(directory); delete it by hand")
                }
            }
            try ArtifactCodec.write(artifact, path: checkpointPath)
            try ArtifactCodec.write(artifact, path: output + "/run.pb")
            return artifact
        }
        /// The schema currently written into the workspace, restored on any exit.
        var installed: InstalledSchema?
        do {
            guard !toRun.isEmpty else { return try finish() }

            /// Builds the workspace as it stands; throws when an unmutated build fails.
            func buildUnmutated() async throws {
                phase = clock.now
                counter.build()
                let baselineBuild = try await executor.execute(
                    driver.buildCommand(workspace: snapshot.root, artifacts: artifacts),
                    directory: snapshot.root,
                    environment: subjectEnvironment(nil),
                    timeout: options.buildTimeout,
                    supervision: buildSupervision
                )
                try writeLog(baselineBuild, path: logs + "/baseline-build.log")
                account("build", since: phase)
                guard baselineBuild.exitStatus == 0, !baselineBuild.timedOut else {
                    let first = CompilerDiagnostics(baselineBuild, snapshotRoot: snapshot.root).errors.first
                    let detail =
                        first.map { ": \($0.path):\($0.line): \($0.message)" }
                        ?? CompilerDiagnostics.firstError(baselineBuild).map { ": \($0)" } ?? ""
                    let hint =
                        options.background
                        ? "; at --background priority a type-check time limit of the subject's can fail it (rerun without)"
                        : ""
                    throw LitmusFailure(
                        "unmutated build failed\(detail)\(hint); no mutant verdicts are valid (logs/baseline-build.log)"
                    )
                }
            }

            /// The baseline from the current build (unmutated, or a schema with no mutant active): harness, workers,
            /// flaky tests, deadlines, and the judge every mutant is decided by.
            func establish() async throws -> Established {
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
                let pool = try ResourcePool(count: allowedWorkers) { index in
                    try WorkerSlot(root: workers, index: index)
                }
                let current = Judge(
                    harness: harness,
                    pool: pool,
                    options: options,
                    counter: counter,
                    baseline: TestCounts(passed: 0, failed: 0, skipped: 0),
                    deadline: options.timeoutCap,
                    parallelDeadline: options.timeoutCap,
                    rerunDeadline: options.timeoutCap
                )
                phase = clock.now
                let usageBefore = ChildUsage.cpuSeconds()
                var baseline = try await current.execute(name: "baseline", activeID: "", deadline: options.timeoutCap)
                let suiteCPU = ChildUsage.cpuSeconds() - usageBefore
                account("tests", since: phase)
                guard baseline.result.outcome == .passed, var baselineCounts = baseline.result.counts,
                    baselineCounts.passed > 0
                else {
                    throw LitmusFailure("unmutated suite did not pass with executed tests: \(baseline.result.reason)")
                }
                var baselineByModule = baseline.result.moduleCounts
                // The Swift Testing test functions, from the baseline's event streams (for `perTestReach`).
                let testFunctions =
                    options.perTestReach ? Self.testFunctions(in: baseline.result.evidence, logs: output) : []
                // Flaky tests: the unmutated suite, repeated; a test failing in any repetition would make a kill that
                // is not the mutant's (the fcheck pilot's timing test), so it is left out of every later run.
                var flaky: [String] = []
                if harness.controlsSwiftTesting, options.baselineRepetitions > 1 {
                    phase = clock.now
                    let probe = try await current.execute(
                        name: "baseline-repetitions",
                        activeID: "",
                        deadline: options.timeoutCap,
                        repetitions: options.baselineRepetitions
                    )
                    flaky = probe.result.failingTests
                    if probe.result.outcome != .passed, flaky.isEmpty {
                        artifact.notes.append(
                            "the flakiness probe (\(options.baselineRepetitions) repetitions) ended "
                                + "\(probe.result.outcome.rawValue) without naming a test: \(probe.result.reason)"
                        )
                    }
                    if !flaky.isEmpty {
                        artifact.notes.append(
                            "\(flaky.count) flaky test(s) left out of every run (failed in "
                                + "\(options.baselineRepetitions) repetitions of the unmutated suite): "
                                + flaky.joined(separator: ", ")
                        )
                        var withoutFlaky = current
                        withoutFlaky.skip = flaky
                        let rebaseline = try await withoutFlaky.execute(
                            name: "baseline-without-flaky",
                            activeID: "",
                            deadline: options.timeoutCap
                        )
                        guard rebaseline.result.outcome == .passed, let counts = rebaseline.result.counts,
                            counts.passed > 0
                        else {
                            throw LitmusFailure(
                                "the unmutated suite without its flaky tests did not pass: \(rebaseline.result.reason)"
                            )
                        }
                        baselineCounts = counts
                        baselineByModule = rebaseline.result.moduleCounts
                        baseline = rebaseline
                    }
                    account("tests", since: phase)
                }
                // The suite's own parallelism (child CPU ÷ wall, alone) bounds the workers: 7 copies of a suite that
                // already keeps 5 cores busy only queue for the same cores (fcheck pilot, 2026-11-02).
                let wall = max(Double(baseline.result.nanoseconds) / 1e9, 0.001)
                // With a width set, each suite runs at most that many tests at once, which bounds its parallelism.
                let parallelism = min(max(1, suiteCPU / wall), Double(options.suiteWidth ?? Int.max))
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
                artifact.policy?.memoryLimitMiB = options.memoryLimitMiB > 0 ? options.memoryLimitMiB : nil
                artifact.policy?.background = options.background
                artifact.policy?.baselineRepetitions =
                    harness.controlsSwiftTesting ? options.baselineRepetitions : nil
                artifact.policy?.flakyTests = flaky
                artifact.policy?.suiteWidth = options.suiteWidth
                artifact.policy?.testTargetSelection = harness.selectsModules && options.selectTestTargets
                var judge = Judge(
                    harness: harness,
                    pool: pool,
                    options: options,
                    counter: counter,
                    baseline: baselineCounts,
                    deadline: deadline,
                    parallelDeadline: parallelDeadline,
                    rerunDeadline: rerunDeadline
                )
                judge.skip = flaky
                judge.baselineByModule = baselineByModule
                if harness.selectsModules, options.selectTestTargets {
                    judge.covering = Self.coveringModules(
                        toRun,
                        root: snapshot.root,
                        modules: Set(baselineByModule.keys)
                    )
                    artifact.notes.append(
                        "test targets selected per mutant from the manifests for \(judge.covering.count) of "
                            + "\(toRun.count) mutants; the others run every test module"
                    )
                }
                return Established(
                    judge: judge,
                    counts: baselineCounts,
                    deadline: deadline,
                    workerCount: workerCount,
                    testFunctions: testFunctions,
                    baseline: baseline
                )
            }

            var established: Established?
            var unmutatedBuilt = false
            if !options.inactiveSchemaBaseline {
                try await buildUnmutated()
                unmutatedBuilt = true
                established = try await establish()
                artifact.policy?.baselineBuild = "unmutated"
            }

            // Changed-line mutants are batched apart and first: a budget spends itself on them before the rest.
            let first = Set(plan.scope?.onChangedLines ?? toRun.map(\.id))
            let classes = [toRun.filter { first.contains($0.id) }, toRun.filter { !first.contains($0.id) }]
            var pending = Array(
                classes.flatMap { SchemaWriter.batches($0, limit: options.batchSize) }.reversed()
            )
            var buildIndex = 0
            var lastBuild = Duration.zero
            while let group = pending.popLast() {
                try Task.checkCancellation()
                if let budgetEnd, clock.now + lastBuild > budgetEnd {
                    // Not started: the next build would end past the budget (estimated by the last one).
                    try untested(
                        group + pending.flatMap { $0 },
                        "the time budget (\(options.budgetSeconds ?? 0) s) ran out before its schema was built",
                        stoppedBy: "time",
                        into: &artifact,
                        sink
                    )
                    pending.removeAll()
                    break
                }
                buildIndex += 1
                let name = "schema-\(buildIndex)"
                let installedGroup = try install(group, in: snapshot, journal: prepared.restore)
                installed = installedGroup
                phase = clock.now
                counter.build()
                let build = try await executor.execute(
                    driver.buildCommand(workspace: snapshot.root, artifacts: artifacts),
                    directory: snapshot.root,
                    environment: subjectEnvironment(nil),
                    timeout: options.buildTimeout,
                    supervision: buildSupervision
                )
                lastBuild = clock.now - phase
                try writeLog(build, path: "\(logs)/\(name)-build.log")
                account("build", since: phase)
                guard build.exitStatus == 0, !build.timedOut else {
                    try installedGroup.restore()
                    installed = nil
                    if established == nil, !unmutatedBuilt {
                        // No baseline yet: the unmutated build tells a broken subject (the run stops) from mutants
                        // that do not compile (the group is split below), and becomes the baseline.
                        try await buildUnmutated()
                        unmutatedBuilt = true
                        established = try await establish()
                        artifact.policy?.baselineBuild = "unmutated (the first schema did not build)"
                    }
                    let diagnostics = CompilerDiagnostics(build, snapshotRoot: snapshot.root)
                    if build.timedOut {
                        for site in group {
                            try record(
                                site,
                                .infrastructureError,
                                "schema build timed out",
                                ["logs/\(name)-build.log"],
                                into: &artifact,
                                sink
                            )
                        }
                    } else if group.count == 1, let site = group.first {
                        // Unviable only when the compiler reports an error in the mutant's own file: this build changed
                        // nothing else. Flow errors ("missing return" after a negated `while true`) point at the end
                        // of the function, not at the mutant's lines. No error, or errors only elsewhere: not its doing.
                        let mutated = Set(installedGroup.rendered.keys)
                        let own = diagnostics.errors.first { mutated.contains($0.path) }
                        let message = (own ?? diagnostics.errors.first)?.message ?? "no compiler diagnostic"
                        try record(
                            site,
                            own != nil ? .unviable : .infrastructureError,
                            own != nil ? "does not compile: \(message)" : "schema build failed elsewhere: \(message)",
                            ["logs/\(name)-build.log"],
                            into: &artifact,
                            sink
                        )
                    } else {
                        let suspects = Set(diagnostics.suspects(in: installedGroup.rendered))
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

                let control: Judge.Execution
                let current: Established
                if let known = established {
                    current = known
                    phase = clock.now
                    control = try await known.judge.execute(
                        name: "\(name)-control",
                        activeID: "",
                        deadline: known.deadline
                    )
                    guard control.result.outcome == .passed, control.result.counts == known.counts else {
                        for site in group {
                            try record(
                                site,
                                .infrastructureError,
                                "inactive schema control differs from the unmutated baseline: \(control.result.reason)",
                                control.result.evidence,
                                into: &artifact,
                                sink
                            )
                        }
                        try installedGroup.restore()
                        installed = nil
                        account("tests", since: phase)
                        continue
                    }
                } else {
                    // The inactive schema is the baseline (ADR 0007): with no mutant active every site evaluates its
                    // original expression, so this build behaves as the unmutated one, and its run is the control too.
                    current = try await establish()
                    established = current
                    artifact.policy?.baselineBuild = "inactive-schema"
                    control = current.baseline
                    phase = clock.now
                }
                let judge = current.judge
                let deadline = current.deadline
                let workerCount = current.workerCount
                for site in group where !control.reached.contains(site.id) {
                    try record(
                        site,
                        .noCoverage,
                        "no test reached the mutated code during the inactive control run",
                        control.result.evidence,
                        into: &artifact,
                        sink
                    )
                }
                let covered = group.filter { control.reached.contains($0.id) }
                if options.perTestReach, judge.harness.selectsTests, !current.testFunctions.isEmpty, !covered.isEmpty {
                    let ids = Set(covered.map(\.id))
                    var reach: [String: [String]] = artifact.perTestReach ?? [:]
                    var durations: [String: Int64] = artifact.testNanoseconds ?? [:]
                    let runs = Array(current.testFunctions.enumerated())
                    try await forEachConcurrently(
                        runs,
                        limit: workerCount,
                        { pair in
                            try await judge.execute(
                                name: "\(name)-reach-\(pair.offset)",
                                activeID: "",
                                deadline: deadline,
                                only: [pair.element]
                            )
                        }
                    ) { index, execution in
                        let test = runs[index].element
                        guard execution.result.outcome == .passed else {
                            artifact.notes.append(
                                "per-test reach: \(test) did not pass alone (\(execution.result.reason))"
                            )
                            return
                        }
                        durations[test] = max(durations[test] ?? 0, execution.result.nanoseconds)
                        for id in execution.reached.intersection(ids) { reach[id, default: []].append(test) }
                    }
                    artifact.perTestReach = reach.mapValues { $0.sorted() }
                    artifact.testNanoseconds = durations
                }
                // Each first run's decision is journalled as it comes (aemi's `forEachConcurrently`): a crash of Litmus
                // loses only the runs in flight. Reruns wait for the parallel pass and run alone, as before.
                var reruns: [Judge.Pending] = []
                var late: [Mutation] = []
                try await forEachConcurrently(
                    covered,
                    limit: workerCount,
                    { site in
                        if let budgetEnd, ContinuousClock.now >= budgetEnd { return Judge.Step.notStarted(site) }
                        return try await judge.first(site)
                    }
                ) { _, step in
                    switch step {
                    case .done(let decision): try record(decision, into: &artifact, sink)
                    case .rerun(let pending): reruns.append(pending)
                    case .notStarted(let site): late.append(site)
                    }
                }
                for pending in reruns {
                    if let budgetEnd, clock.now >= budgetEnd {
                        late.append(pending.site)
                        continue
                    }
                    try record(try await judge.finish(pending), into: &artifact, sink)
                }
                if !late.isEmpty {
                    try untested(
                        late,
                        "the time budget (\(options.budgetSeconds ?? 0) s) ran out before it was decided",
                        stoppedBy: "time",
                        into: &artifact,
                        sink
                    )
                }
                account("tests", since: phase)
                try installedGroup.restore()
                installed = nil
                try ArtifactCodec.write(artifact, path: checkpointPath)
            }
            return try finish()
        } catch {
            try? installed?.restore()
            releaseWorkspace()
            if let journal = prepared.restore, !journal.outstanding.isEmpty {
                artifact.notes.append(
                    "in place: \(journal.outstanding.count) file(s) could not be restored; run `litmus restore \(root)`"
                )
            }
            artifact.notes.append("run stopped: \(error); partial evidence is not a successful run")
            timings["total"] = seconds(clock.now - started)
            artifact.timings = timings
            artifact.cost = cost(workspace: prepared.removable ? snapshot.root : nil)
            do { try ArtifactCodec.write(artifact, path: checkpointPath) } catch let writeError {
                throw LitmusFailure("execution failed: \(error); checkpoint failed: \(writeError)")
            }
            throw error
        }
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

    /// Records `sites` as not run within the budget.
    private func untested(
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
    /// manifests (`ProjectClassification.testTargets(covering:)`, ADR-0030 there), as module names, among `modules`
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

    private func record(_ decision: Judge.Decision, into artifact: inout RunArtifact, _ sink: Sink) throws {
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

    private func record(
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
    private func record(_ result: MutationResult, into artifact: inout RunArtifact, _ sink: Sink) throws {
        guard let index = artifact.results.firstIndex(where: { $0.mutation.id == result.mutation.id }) else {
            throw LitmusFailure("internal: result for unplanned mutant \(result.mutation.id)")
        }
        var result = result
        result.reuseKey = artifact.results[index].reuseKey
        artifact.results[index] = result
        try sink.journal.append(result)
        if let store = sink.store, let key = result.reuseKey, result.reusedFrom == nil {
            // A cache: a record that cannot be written is a later miss, never a failed run.
            do { try store.put(key, result, runID: sink.runID) } catch {
                artifact.notes.append("result store: \(result.mutation.id) not stored: \(error)")
            }
        }
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
    /// In place, each original is made recoverable through `journal` before its file is rewritten.
    private func install(_ group: [Mutation], in snapshot: WorkspaceSnapshot, journal: InPlaceJournal?) throws
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
    private func requireCleanGit(_ paths: [String], root: String) async throws {
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

/// The current schema files of a batch, by absolute snapshot path.
struct InstalledSchema {
    let originals: [String: Data]
    let rendered: [String: RenderedSchema]
    /// In place: restores go through the journal, which puts an original back only over the schema it recorded.
    var journal: InPlaceJournal? = nil

    func restore() throws {
        if let journal {
            try journal.restoreAll()
            return
        }
        for (path, data) in originals { try AtomicFile.replace(at: path, with: [UInt8](data), durability: .none) }
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

    /// The first line saying `error:` of any kind (`xcodebuild: error: Unable to find a device…`), at most 300
    /// characters: what a failed build says when no compiler diagnostic names a file.
    static func firstError(_ build: ProcessOutput) -> String? {
        let text = plain(build.stdout + Array("\n".utf8) + build.stderr)
        guard let line = text.split(whereSeparator: \.isNewline).first(where: { $0.contains("error:") }) else {
            return nil
        }
        return String(line.trimmingCharacters(in: .whitespaces).prefix(300))
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
    let counter: RunCounter
    let baseline: TestCounts
    let deadline: Int
    /// The deadline of a mutant's first run among parallel workers: contention slows every suite.
    let parallelDeadline: Int
    let rerunDeadline: Int
    /// Swift Testing tests left out of every run: they failed in the unmutated suite's repetitions.
    var skip: [String] = []
    /// For each mutant, the test modules that can reach its file; a mutant without an entry runs every module.
    var covering: [String: Set<String>] = [:]
    /// The unmutated suite's counts per module, what a mutant's selected modules must pass.
    var baselineByModule: [String: TestCounts] = [:]

    /// The counts a passing run of `site` must have: its selected modules', or the whole baseline.
    func expected(_ site: Mutation) -> TestCounts {
        guard let modules = covering[site.id] else { return baseline }
        var passed = 0, skipped = 0
        for module in modules {
            passed += baselineByModule[module]?.passed ?? 0
            skipped += baselineByModule[module]?.skipped ?? 0
        }
        return TestCounts(passed: passed, failed: 0, skipped: skipped)
    }

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
        only: [String]? = nil,
        modules: Set<String>? = nil,
        repetitions: Int? = nil,
        alone: Bool = false
    ) async throws -> Execution {
        let slot = try await pool.acquire()
        defer { pool.checkin(slot) }
        counter.test()
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
        // A run alone decides a timeout: never at background priority.
        request.supervision = options.supervision(background: alone ? false : nil)
        if harness.selectsModules { request.onlyModules = only == nil ? modules : nil }
        if harness.controlsSwiftTesting {
            request.skipSwiftTesting = skip
            request.repetitions = repetitions
            request.parallelizationWidth = options.suiteWidth
        }
        let result = try await harness.run(request)
        return Execution(result: result, reached: ActivationEnvironment.reached(in: coverage))
    }

    /// What a mutant's first, parallel run decided, or the rerun it needs.
    enum Step: Sendable {
        case done(Decision)
        /// A failure without activation, a crash, a timeout, or a kill to confirm: rerun after the parallel pass, alone.
        case rerun(Pending)
        /// Not started: the time budget ran out first.
        case notStarted(Mutation)
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
            only: only,
            modules: covering[site.id],
            alone: !suffix.isEmpty
        )
        ledger.evidence += execution.result.evidence
        ledger.nanoseconds += execution.result.nanoseconds
        return execution
    }

    /// The first run of one reached mutant, among the parallel workers, with `parallelDeadline`.
    func first(_ site: Mutation) async throws -> Step {
        var ledger = Ledger(site: site, baseline: expected(site), evidence: [], nanoseconds: 0)
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
            baseline: expected(site),
            evidence: pending.evidence,
            nanoseconds: pending.nanoseconds
        )
        if pending.outcome == .failed, pending.activated, options.killConfirmation == .full {
            let control = try await run(site, "-control", active: false, deadline: rerunDeadline, ledger: &ledger)
            let again = try await run(site, "-confirm", active: true, deadline: rerunDeadline, ledger: &ledger)
            guard control.result.outcome == .passed, control.result.counts == ledger.baseline,
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
    public static let current = "0.3.0-dev"
}
