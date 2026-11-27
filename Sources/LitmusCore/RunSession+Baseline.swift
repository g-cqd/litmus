internal import AemiRuntime
internal import Foundation

extension RunSession {
    /// The harness the baseline settled on, its worker pool, and the judge over them, before deadlines exist.
    struct BaselineRun {
        var harness: any TestHarness
        var allowedWorkers: Int
        var pool: ResourcePool<WorkerSlot>
        var judge: Judge
        var execution: Judge.Execution
        var suiteCPU: Double
        var counts = TestCounts(passed: 0, failed: 0, skipped: 0)
    }

    /// The baseline from the current build (unmutated, or a schema with no mutant active): harness, workers,
    /// flaky tests, deadlines, and the judge every mutant is decided by.
    func establish() async throws -> Established {
        phase = clock.now
        startSimulatorPool(extraSimulators: false)
        if let bootTask {
            await bootTask.value
            self.bootTask = nil
        }
        let harness = try await baselineHarness()
        account("discovery", since: phase)
        phase = clock.now
        let singlePassReach = options.perTestReach && harness.selectsTests && harness.controlsSwiftTesting
        var run = try await runBaseline(on: harness, singlePassReach: singlePassReach)
        account("tests", since: phase)
        guard run.execution.result.outcome == .passed, let counts = run.execution.result.counts, counts.passed > 0
        else {
            throw LitmusFailure("unmutated suite did not pass with executed tests: \(run.execution.result.reason)")
        }
        run.counts = counts
        try shareSimulatorWorkers(&run)
        try shareUISessions(&run)
        // The Swift Testing test functions, from the baseline's event streams (for `perTestReach`).
        let testFunctions =
            options.perTestReach ? Runner.testFunctions(in: run.execution.result.evidence, logs: output) : []
        let flaky = try await removeFlakyTests(&run, singlePassReach: singlePassReach)
        let limits = deadlines(for: run)
        recordPolicy(run, limits, flaky: flaky)
        let judge = try assembleJudge(run, limits, flaky: flaky)
        return Established(
            judge: judge,
            counts: run.counts,
            deadline: limits.deadline,
            workerCount: limits.workers,
            testFunctions: testFunctions,
            baseline: run.execution
        )
    }

    /// The harness for this run's destination; with `--simulators` above 1, `xcodebuild` over a simulator fleet.
    func baselineHarness() async throws -> any TestHarness {
        var notes: [String] = []
        var harness = try await runner.makeHarness(
            driver: driver,
            options: options,
            workspace: snapshot.root,
            artifacts: artifacts,
            logs: logs,
            fleet: nil,
            notes: &notes
        )
        if harness is XcodeHarness<Executor>, options.simulators > 1 {
            startSimulatorPool(extraSimulators: true)
            harness = xcodeHarness(fleet: await simulatorFleet(notes: &notes))
        } else if options.simulators > 1 {
            if resolvedDevice != nil {
                notes.append(
                    "--simulators \(options.simulators) pool skipped: simulator-direct runs concurrent workers on the booted destination simulator without extra simulator boots"
                )
            } else {
                notes.append(
                    "--simulators \(options.simulators) ignored: the run is not on an iOS Simulator destination"
                )
            }
        }
        artifact.notes += notes
        return harness
    }

    func xcodeHarness(fleet: SimulatorFleet?) -> XcodeHarness<Executor> {
        XcodeHarness(
            executor: executor,
            driver: driver,
            workspace: snapshot.root,
            artifacts: artifacts,
            logs: logs,
            fleet: fleet,
            keepResultBundles: options.keepResultBundles
        )
    }

    /// A judge for `harness` with placeholder deadlines, for baseline runs only.
    func makeJudge(for harness: any TestHarness) throws -> (
        allowedWorkers: Int, pool: ResourcePool<WorkerSlot>, judge: Judge
    ) {
        let allowedWorkers = min(options.jobs, harness.maximumWorkers)
        let workers = self.workers
        let pool = try ResourcePool(count: allowedWorkers) { index in
            try WorkerSlot(root: workers, index: index)
        }
        let judge = Judge(
            harness: harness,
            pool: pool,
            options: options,
            counter: counter,
            baseline: TestCounts(passed: 0, failed: 0, skipped: 0),
            deadline: options.timeoutCap,
            parallelDeadline: options.timeoutCap,
            rerunDeadline: options.timeoutCap
        )
        return (allowedWorkers, pool, judge)
    }

    /// The unmutated suite on `harness`, falling back to `xcodebuild` and quarantining failing targets as allowed.
    func runBaseline(on harness: any TestHarness, singlePassReach: Bool) async throws -> BaselineRun {
        let made = try makeJudge(for: harness)
        var judge = made.judge
        // A target quarantined by an earlier schema's baseline stays out.
        if options.skipFailingTargets { judge.quarantined = Set(quarantined.keys) }
        let usageBefore = ChildUsage.cpuSeconds()
        let execution = try await judge.execute(
            name: "baseline",
            activeID: "",
            deadline: options.timeoutCap,
            collectPerTestReach: singlePassReach
        )
        var run = BaselineRun(
            harness: harness,
            allowedWorkers: made.allowedWorkers,
            pool: made.pool,
            judge: judge,
            execution: execution,
            suiteCPU: ChildUsage.cpuSeconds() - usageBefore
        )
        // The helper `xcodebuild` replaced, retried once `xcodebuild` has quarantined the targets that truly fail.
        let fellBackFrom = try await fallBackToXcodebuild(&run)
        if options.skipFailingTargets, run.harness.selectsModules {
            try await quarantineFailingTargets(&run, helper: fellBackFrom, singlePassReach: singlePassReach)
        }
        return run
    }

    /// App-hosted unit tests that depend on UIApplication or host-app resources cannot run without launching the
    /// `.app`: when the simulator helper fails them, `xcodebuild` runs the baseline instead of failing the run.
    func fallBackToXcodebuild(_ run: inout BaselineRun) async throws -> SimulatorDirectHarness<Executor>? {
        guard run.execution.result.outcome != .passed || (run.execution.result.counts?.passed ?? 0) == 0,
            let direct = run.harness as? SimulatorDirectHarness<Executor>, direct.hasAppHostedTargets
        else { return nil }
        artifact.notes.append(
            "simulator helper could not pass the app-hosted baseline (\(run.execution.result.reason)); falling back to xcodebuild"
        )
        var notes: [String] = []
        if options.simulators > 1 { startSimulatorPool(extraSimulators: true) }
        let fleet = await simulatorFleet(notes: &notes)
        artifact.notes += notes
        run.harness = xcodeHarness(fleet: fleet)
        let made = try makeJudge(for: run.harness)
        (run.allowedWorkers, run.pool, run.judge) = (made.allowedWorkers, made.pool, made.judge)
        let usageBefore = ChildUsage.cpuSeconds()
        run.execution = try await run.judge.execute(
            name: "baseline-xcodebuild",
            activeID: "",
            deadline: options.timeoutCap
        )
        run.suiteCPU = ChildUsage.cpuSeconds() - usageBefore
        return direct
    }

    /// `--skip-failing-targets`: one module at a time, as each failing bundle ends its run, so the next one shows on
    /// the rerun. A helper `xcodebuild` replaced gets another chance without the quarantined targets.
    func quarantineFailingTargets(
        _ run: inout BaselineRun,
        helper: SimulatorDirectHarness<Executor>?,
        singlePassReach: Bool
    ) async throws {
        run.judge.quarantined = Set(quarantined.keys)
        for attempt in 1...64 {
            guard run.execution.result.outcome != .passed || (run.execution.result.counts?.passed ?? 0) == 0,
                let module = Self.failedModule(run.execution.result), quarantined[module] == nil
            else { break }
            quarantined[module] = run.execution.result.reason
            run.judge.quarantined.insert(module)
            artifact.notes.append(
                "test target \(module) failed unmutated (\(run.execution.result.reason)) and was excluded "
                    + "(--skip-failing-targets); mutants only it covers are not run"
            )
            run.execution = try await run.judge.execute(
                name: "baseline-quarantine-\(attempt)",
                activeID: "",
                deadline: options.timeoutCap,
                collectPerTestReach: singlePassReach
            )
        }
        // The helper failed on a target `xcodebuild` also fails: without the quarantined targets it may pass, and
        // it is much faster. A target that fails only under the helper keeps the run on `xcodebuild`.
        guard let helper, !quarantined.isEmpty, run.execution.result.outcome == .passed else { return }
        let made = try makeJudge(for: helper)
        var helperJudge = made.judge
        helperJudge.quarantined = Set(quarantined.keys)
        let retry = try await helperJudge.execute(
            name: "baseline-helper-quarantined",
            activeID: "",
            deadline: options.timeoutCap,
            collectPerTestReach: singlePassReach
        )
        guard retry.result.outcome == .passed, (retry.result.counts?.passed ?? 0) > 0 else { return }
        run.harness = helper
        (run.allowedWorkers, run.pool, run.judge) = (made.allowedWorkers, made.pool, helperJudge)
        run.execution = retry
        artifact.notes.append("simulator helper passes without the quarantined test target(s); back on the helper")
    }

    /// The simulator helper ran the baseline: its bundles can be served by shared workers too (the helper's serve
    /// mode), decided per batch like the macOS ones. Wrapped only now, once the helper is the harness that stays.
    func shareSimulatorWorkers(_ run: inout BaselineRun) throws {
        guard options.sharedProcess != .off, let simulator = run.harness as? SimulatorDirectHarness<Executor> else {
            return
        }
        let scratch = artifacts + "/shared-process"
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        let helperPath = simulator.helper.helper
        let shared = SharedProcessHarness(
            direct: simulator,
            helper: { helperPath },
            scratch: scratch,
            token: options.environmentToken,
            mode: options.sharedProcess
        )
        let quarantinedNow = run.judge.quarantined
        run.harness = shared
        let made = try makeJudge(for: shared)
        (run.allowedWorkers, run.pool, run.judge) = (made.allowedWorkers, made.pool, made.judge)
        run.judge.quarantined = quarantinedNow
    }

    /// `xcodebuild` on one destination with UI test bundles: a batch's UI-test first runs share one session, one
    /// test-plan configuration per mutant (`UISessionHarness`).
    func shareUISessions(_ run: inout BaselineRun) throws {
        guard options.sharedProcess != .off, let xcode = run.harness as? XcodeHarness<Executor>, xcode.fleet == nil,
            try UISessionHarness<Executor>.hasUITests(products: artifacts + "/DerivedData/Build/Products")
        else { return }
        let quarantinedNow = run.judge.quarantined
        let shared = UISessionHarness(inner: xcode)
        run.harness = shared
        let made = try makeJudge(for: shared)
        (run.allowedWorkers, run.pool, run.judge) = (made.allowedWorkers, made.pool, made.judge)
        run.judge.quarantined = quarantinedNow
    }
}
