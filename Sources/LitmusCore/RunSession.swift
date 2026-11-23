internal import AemiIO
internal import AemiJSON
internal import AemiRuntime
internal import Foundation
internal import ProjectModel
internal import SourceCorpus

/// One run of `MutationRunner`, as stages over shared state: scope fast path, workspace, plan and provenance, reuse,
/// work selection, baseline, then the schema batches. Each stage is a method; `run()` only orders them.
final class RunSession<Executor: ProcessExecutor> {
    typealias Runner = MutationRunner<Executor>
    typealias Sink = Runner.Sink
    typealias Established = Runner.Established
    let runner: Runner
    let executor: Executor
    let driver: BuildDriver
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
    var buildSupervision = Supervision()
    var workspaceReleased = false
    /// The schema currently written into the workspace, restored on any exit.
    var installed: InstalledSchema?

    init(runner: Runner, executor: Executor, driver: BuildDriver, outputDirectory: String, options: RunOptions) throws {
        try options.validate()
        self.runner = runner
        self.executor = executor
        self.driver = driver
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
        try await prepareWorkspace()
        // Planning and configuration validation can fail before the execution checkpoint exists.
        defer { releaseWorkspace() }
        try await planAndProvenance()
        try await applyReuse()
        try await selectWork()
        do {
            guard !toRun.isEmpty else { return try finish() }
            try await runBatches()
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

    /// The fast path: a change reaching no site ends here, before any copy, build or toolchain query.
    func scopeFastPath() async throws -> RunArtifact? {
        guard let scope = options.scope else { return nil }
        // The fast path: a change reaching no site ends here, before any copy, build or toolchain query.
        let sourcePlan = try await MutationPlanner.plan(
            root: root,
            exclude: options.exclude,
            include: options.include,
            packagePath: driver.packagePath,
            jobs: 8,
            scope: scope,
            operators: options.operators
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
        return nil
    }

    /// Creates the owned workspace the run builds and mutates in.
    func prepareWorkspace() async throws {
        prepared = try await PreparedWorkspace.prepare(
            options.workspace,
            source: root,
            output: output,
            buildDirectory: options.buildDirectory.map(canonicalNew)
        )
        snapshot = prepared.snapshot
        artifacts = prepared.buildDirectory
        try FileManager.default.createDirectory(atPath: artifacts, withIntermediateDirectories: true)
    }

    /// Ends the workspace: restores what is still rewritten (in place), releases the lock.
    func releaseWorkspace() {
        guard !workspaceReleased else { return }
        workspaceReleased = true
        if let journal = prepared.restore {
            _ = try? journal.restoreAll()
            prepared.lock?.release()
            journal.tidy()
        } else {
            prepared.lock?.release()
        }
    }

    /// Plans the sites in the workspace and records the run's provenance and checkpoint state.
    func planAndProvenance() async throws {
        account("snapshot", since: phase)
        try driver.validatePackage(workspace: snapshot.root)
        try XcodeTestConfiguration.preflight(driver: driver, workspace: snapshot.root)
        phase = clock.now
        let clonePlan = try await MutationPlanner.plan(
            root: snapshot.root,
            exclude: options.exclude,
            include: options.include,
            packagePath: driver.packagePath,
            jobs: 8,
            scope: options.scope,
            operators: options.operators
        )
        account("plan", since: phase)
        plan = MutationPlan(
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
        var shardRecord: ShardRecord?
        if let shard = options.shard {
            (plan, shardRecord) = Sharding.select(plan, shard)
        }
        guard Set(plan.mutations.map(\.id)).count == plan.mutations.count else {
            throw LitmusFailure("mutation ID collision")
        }
        let toolchain = try await executor.execute(
            ToolCommand(
                executable: "/usr/bin/xcrun",
                arguments: [driver.usesXcode ? "xcodebuild" : "swift", "-version"]
            ),
            directory: driver.executionDirectory(workspace: snapshot.root),
            environment: subjectEnvironment(nil),
            timeout: 60
        )
        guard toolchain.exitStatus == 0 else { throw LitmusFailure("toolchain identification failed") }
        provenance = RunProvenance(
            toolVersion: LitmusVersion.current,
            snapshotSHA256: snapshot.digest,
            inputs: snapshot.entries,
            driver: driver,
            toolchain: String(decoding: toolchain.stdout, as: UTF8.self),
            startedAt: ISO8601DateFormatter().string(from: Date()),
            executionPolicy: RunArtifact.executionPolicy
        )
        artifact = RunArtifact(provenance: provenance, plan: plan)
        artifact.shard = shardRecord
        for link in snapshot.skippedLinks {
            artifact.notes.append("symbolic link left out of the workspace (never followed): \(link)")
        }
        artifact.notes += prepared.notes
        if prepared.restore != nil {
            // In place: every file to mutate must be tracked and unmodified, so git can restore it as a last resort.
            try await runner.requireCleanGit(Set(plan.mutations.map(\.path)).sorted(), root: root)
            artifact.notes.append(
                "in place: the subject root is the workspace; originals are backed up in .litmus/restore before each "
                    + "rewrite and restored after each batch"
            )
        }

    }

    /// Reuse: every result carries its key, so any run can be resumed or seed a store; a verdict is reused only when
    /// its key matches, and says where it came from.
    func applyReuse() async throws {
        phase = clock.now
        phase = clock.now
        reuse = try ReuseContext(
            mode: options.reuseMode,
            root: snapshot.root,
            entries: snapshot.entries,
            wholeSnapshot: snapshot.digest,
            mutations: plan.mutations,
            closureKnown: driver.container == nil,
            inPlace: prepared.restore != nil,
            context: ReuseContextInputs(
                toolVersion: LitmusVersion.current,
                executionPolicy: RunArtifact.executionPolicy,
                toolchain: provenance.toolchain,
                driver: driver,
                harness: options.harness.rawValue + (options.simulatorHarness ? "" : "/xcodebuild"),
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
        if !reuse.outsideRoot.isEmpty {
            artifact.notes.append(
                "\(reuse.outsideRoot.count) file(s) belong to a package depending on a local package outside the root; "
                    + "their verdicts are never reused (the root's inventory cannot see those files change)"
            )
        }
        store = try options.resultStore.map {
            try ResultStore(
                directory: $0,
                readOnly: options.storeReadOnly,
                limitMiB: options.storeLimitMiB,
                forbidden: root,
                secret: ProcessInfo.processInfo.environment["LITMUS_STORE_KEY"]
            )
        }
        let previous = try options.resume.map { try Runner.previousResults(runDirectory: $0) } ?? [:]
        nightly = try options.reachFrom.map { try ArtifactCodec.read(RunArtifact.self, path: $0) }
        let checkpointPath = output + "/run.json"
        try ArtifactCodec.write(artifact, path: checkpointPath)
        sink = Sink(
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
            try runner.record(result, into: &artifact, sink)
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
    }

    /// What runs: the mutants without a reused verdict, in plan order (changed lines first), within the budget.
    func selectWork() async throws {
        let decided = Set(artifact.results.filter { $0.reusedFrom != nil }.map(\.mutation.id))
        toRun = plan.mutations.filter { !decided.contains($0.id) }
        if options.budgetSeconds != nil || options.maxMutants != nil {
            artifact.budget = BudgetRecord(seconds: options.budgetSeconds, maxMutants: options.maxMutants)
        }
        if let limit = options.maxMutants, toRun.count > limit {
            let over = Array(toRun[limit...])
            toRun = Array(toRun[..<limit])
            try runner.untested(over, "beyond --max-mutants \(limit)", stoppedBy: "max-mutants", into: &artifact, sink)
        }

        // Builds run at the run's priority, without the memory limit: a compiler may use more than a test should.
        buildSupervision = Supervision()
        buildSupervision.background = options.background
    }

    /// Ends the run: complete, timed, costed, the workspace removed unless kept.
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
            where !Runner.remove(directory) {
                artifact.notes.append("could not remove \(directory); delete it by hand")
            }
        }
        try ArtifactCodec.write(artifact, path: checkpointPath)
        try ArtifactCodec.write(artifact, path: output + "/run.pb")
        return artifact
    }

    /// Builds the workspace as it stands; throws when an unmutated build fails.
    /// Builds the workspace as it stands; throws when an unmutated build fails.
    func buildUnmutated() async throws {
        phase = clock.now
        counter.build()
        let baselineBuild = try await executor.execute(
            driver.buildCommand(workspace: snapshot.root, artifacts: artifacts),
            directory: driver.executionDirectory(workspace: snapshot.root),
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

    /// The baseline from the current build (unmutated, or a schema with no mutant active): harness, workers,
    /// flaky tests, deadlines, and the judge every mutant is decided by.
    /// flaky tests, deadlines, and the judge every mutant is decided by.
    func establish() async throws -> Established {
        phase = clock.now
        var harnessNotes: [String] = []
        let harness = try await runner.makeHarness(
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
            options.perTestReach ? Runner.testFunctions(in: baseline.result.evidence, logs: output) : []
        // Flaky tests: the unmutated suite, repeated; a test failing in any repetition would make a kill that
        // is not the mutant's (the fcheck pilot's timing test), so it is left out of every later run.
        var flaky: [String] = []
        if harness.controlsSwiftTesting, let nightly, let known = nightly.policy?.flakyTests {
            // The nightly's flaky tests, its probe not repeated (t49): a test that became flaky since is
            // caught only by kill confirmation.
            flaky = known
            artifact.notes.append(
                "flaky tests from \(options.reachFrom ?? "the nightly run") (\(known.count)); the probe was not run"
            )
            if !known.isEmpty {
                var withoutFlaky = current
                withoutFlaky.skip = known
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
        } else if harness.controlsSwiftTesting, options.baselineRepetitions > 1 {
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
        artifact.policy?.operators = options.operators.map(\.rawValue).sorted()
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
        if let nightly, nightly.reuse?.mode == .closure, let reach = nightly.perTestReach,
            let counts = nightly.testCounts
        {
            // The nightly's per-test reach, for the mutants whose key is the same: nothing that could change
            // which tests reach them changed (t49).
            let keys = Dictionary(
                nightly.results.compactMap { result in result.reuseKey.map { (result.mutation.id, $0) } },
                uniquingKeysWith: { first, _ in first }
            )
            var used = 0, changed = 0
            let running = Set(toRun.map(\.id))
            for result in artifact.results where running.contains(result.mutation.id) {
                guard let key = result.reuseKey, keys[result.mutation.id] == key else {
                    changed += 1
                    continue
                }
                guard let tests = reach[result.mutation.id] else { continue }
                judge.reach[result.mutation.id] = Set(tests)
                used += 1
            }
            judge.testCounts = counts
            artifact.notes.append(
                "per-test reach from \(options.reachFrom ?? "the nightly run") used for \(used) of \(toRun.count) "
                    + "mutants (\(changed) with a changed key; the rest not reached by any test alone)"
            )
        }
        if harness.selectsModules, options.selectTestTargets {
            judge.covering = Runner.coveringModules(
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

    /// Builds each batch's schema, bisects the ones that do not compile, controls and judges the reached mutants.
    func runBatches() async throws {
        let budgetEnd = self.budgetEnd
        var established: Established?
        var unmutatedBuilt = false
        /// Each test's counts alone (per-test reach), across schemas.
        var perTestCounts: [String: TestCounts] = [:]
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
                try runner.untested(
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
            let installedGroup = try runner.install(group, in: snapshot, journal: prepared.restore)
            installed = installedGroup
            phase = clock.now
            counter.build()
            let build = try await executor.execute(
                driver.buildCommand(workspace: snapshot.root, artifacts: artifacts),
                directory: driver.executionDirectory(workspace: snapshot.root),
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
                        try runner.record(
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
                    try runner.record(
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
                        try runner.record(
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
                // The inactive schema is the baseline: with no mutant active every site evaluates its
                // original expression, so this build behaves as the unmutated one, and its run is the control too.
                current = try await establish()
                established = current
                artifact.policy?.baselineBuild = "inactive-schema"
                control = current.baseline
                phase = clock.now
            }
            var judge = current.judge
            let deadline = current.deadline
            let workerCount = current.workerCount
            for site in group where !control.reached.contains(site.id) {
                try runner.record(
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
                let probing = judge
                try await forEachConcurrently(
                    runs,
                    limit: workerCount,
                    { pair in
                        try await probing.execute(
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
                    if let counts = execution.result.counts { perTestCounts[test] = counts }
                    for id in execution.reached.intersection(ids) { reach[id, default: []].append(test) }
                }
                artifact.perTestReach = reach.mapValues { $0.sorted() }
                artifact.testNanoseconds = durations
                artifact.testCounts = perTestCounts
                // This schema's reach decides its mutants: selection and the kill check (t37, t38).
                for site in covered { judge.reach[site.id] = Set(reach[site.id] ?? []) }
            }
            judge.testCounts.merge(perTestCounts) { _, new in new }
            let deciding = judge
            // Each first run's decision is journalled as it comes (aemi's `forEachConcurrently`): a crash of Litmus
            // loses only the runs in flight. Reruns wait for the parallel pass and run alone, as before.
            var reruns: [Judge.Pending] = []
            var late: [Mutation] = []
            try await forEachConcurrently(
                covered,
                limit: workerCount,
                { site in
                    if let budgetEnd, ContinuousClock.now >= budgetEnd { return Judge.Step.notStarted(site) }
                    return try await deciding.first(site)
                }
            ) { _, step in
                switch step {
                case .done(let decision): try runner.record(decision, into: &artifact, sink)
                case .rerun(let pending): reruns.append(pending)
                case .notStarted(let site): late.append(site)
                }
            }
            for pending in reruns {
                if let budgetEnd, clock.now >= budgetEnd {
                    late.append(pending.site)
                    continue
                }
                try runner.record(try await judge.finish(pending), into: &artifact, sink)
            }
            if !late.isEmpty {
                try runner.untested(
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
    }
}
