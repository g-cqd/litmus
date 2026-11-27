internal import Foundation
internal import SourceCorpus

/// One run of `MutationRunner`, as stages over shared state: scope fast path, workspace, plan and provenance, reuse,
/// work selection, baseline, then the schema batches. Each stage is a method; `run()` only orders them.
final class RunSession<Executor: ProcessExecutor> {
    typealias Runner = MutationRunner<Executor>

    typealias Sink = Runner.Sink

    typealias Established = Runner.Established

    let runner: Runner

    let executor: Executor

    var driver: BuildDriver

    let options: RunOptions

    let clock = ContinuousClock()

    let started: ContinuousClock.Instant

    let output: String, root: String, logs: String, workers: String, checkpointPath: String

    let counter = RunCounter()

    let budgetEnd: ContinuousClock.Instant?

    var timings: [String: Double] = [:]

    var phase: ContinuousClock.Instant

    // Set by the workspace and planning stages, never read before them.
    var prepared: PreparedWorkspace!

    var snapshot: WorkspaceSnapshot!

    var artifacts = ""

    var plan: MutationPlan!

    var artifact: RunArtifact!

    var provenance: RunProvenance!

    var reuse: ReuseContext!

    var store: ResultStore?

    var nightly: RunArtifact?

    var sink: Sink!

    var toRun: [Mutation] = []

    /// What each mutant cost in an earlier run, to start the slowest first.
    var durationHints: [String: Int64] = [:]

    var buildSupervision = Supervision()

    var workspaceReleased = false

    var resolvedDestinationNote: String?

    /// The simulator the destination names, when the run is on one.
    var resolvedDevice: SimulatorDevice?

    /// Simulators made for this run (`--simulators`), being made while the first schema builds.
    var poolTask: Task<SimulatorPool<Executor>, any Error>?

    /// A single shutdown destination simulator being booted while the first schema builds.
    var bootTask: Task<Void, Never>?

    var poolTornDown = false

    /// Test modules that failed unmutated, with why (`--skip-failing-targets`); left out of every later run.
    var quarantined: [String: String] = [:]

    /// The schema currently written into the workspace, restored on any exit.
    var installed: InstalledSchema?

    init(runner: Runner, executor: Executor, driver: BuildDriver, outputDirectory: String, options: RunOptions) throws {
        try options.validate()
        self.runner = runner
        self.executor = executor
        self.driver = driver
        var options = options
        if options.environmentToken.isEmpty {
            options.environmentToken = ActivationEnvironment.token(for: driver.root)
        }
        self.options = options
        let now = clock.now
        started = now
        phase = now
        let fm = FileManager.default
        output = canonicalNew(outputDirectory)
        root = SourcePath.canonical(driver.root)
        guard output != root, !output.hasPrefix(root + "/"), !fm.fileExists(atPath: output) else {
            throw LitmusFailure(
                "output directory \(output) must not already exist and must be outside source root \(root); choose a new --output path or move the previous run (use --resume to reuse its verdicts)"
            )
        }
        try driver.validatePackage(workspace: root)
        try XcodeTestConfiguration.preflight(driver: driver, workspace: root)
        logs = output + "/logs"
        workers = output + "/workers"
        checkpointPath = output + "/run.json"
        for directory in [output, logs, workers] {
            try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        budgetEnd = options.budgetSeconds.map { now + .seconds($0) }
    }

    func account(_ phase: String, since start: ContinuousClock.Instant) {
        timings[phase, default: 0] += seconds(clock.now - start)
    }

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

    /// Orders the stages; any failure restores the workspace and checkpoints what is known.
    func run() async throws -> RunArtifact {
        phase = clock.now
        if let finished = try await scopeFastPath() { return finished }
        try await resolveDestination()
        try await prepareWorkspace()
        // Planning and configuration validation can fail before the execution checkpoint exists.
        defer { releaseWorkspace() }
        try await planAndProvenance()
        try await applyReuse()
        try await selectWork()
        do {
            guard !toRun.isEmpty else { return try finish() }
            try await runBatches()
            await teardownSimulators()
            return try finish()
        } catch {
            await teardownSimulators()
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
}
