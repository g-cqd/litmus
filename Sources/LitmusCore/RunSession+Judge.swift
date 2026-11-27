internal import Foundation

extension RunSession {
    /// The deadlines and worker count the baseline's cost sets for every later run.
    struct Deadlines {
        let workers: Int
        let deadline: Int
        let parallel: Int
        let rerun: Int
        let parallelism: Double
    }

    /// Flaky tests: the unmutated suite, repeated; a test failing in any repetition would make a kill that is not the
    /// mutant's (the fcheck pilot's timing test), so it is left out of every later run.
    func removeFlakyTests(_ run: inout BaselineRun, singlePassReach: Bool) async throws -> [String] {
        if run.harness.controlsSwiftTesting, let nightly, let known = nightly.policy?.flakyTests {
            // The nightly's flaky tests, its probe not repeated (t49): a test that became flaky since is caught only
            // by kill confirmation.
            artifact.notes.append(
                "flaky tests from \(options.reachFrom ?? "the nightly run") (\(known.count)); the probe was not run"
            )
            if !known.isEmpty { try await rebaseline(&run, without: known, singlePassReach: singlePassReach) }
            return known
        }
        guard run.harness.controlsSwiftTesting, options.baselineRepetitions > 1 else { return [] }
        phase = clock.now
        let probe = try await run.judge.execute(
            name: "baseline-repetitions",
            activeID: "",
            deadline: options.timeoutCap,
            repetitions: options.baselineRepetitions
        )
        let flaky = probe.result.failingTests
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
            try await rebaseline(&run, without: flaky, singlePassReach: singlePassReach)
        }
        account("tests", since: phase)
        return flaky
    }

    /// The unmutated suite again without `flaky`; it becomes the baseline.
    func rebaseline(_ run: inout BaselineRun, without flaky: [String], singlePassReach: Bool) async throws {
        var withoutFlaky = run.judge
        withoutFlaky.skip = flaky
        let execution = try await withoutFlaky.execute(
            name: "baseline-without-flaky",
            activeID: "",
            deadline: options.timeoutCap,
            collectPerTestReach: singlePassReach
        )
        guard execution.result.outcome == .passed, let counts = execution.result.counts, counts.passed > 0 else {
            throw LitmusFailure(
                "the unmutated suite without its flaky tests did not pass: \(execution.result.reason)"
            )
        }
        run.counts = counts
        run.execution = execution
    }

    /// The suite's own parallelism (child CPU ÷ wall, alone) bounds the workers: 7 copies of a suite that already
    /// keeps 5 cores busy only queue for the same cores (fcheck pilot, 2026-11-02).
    func deadlines(for run: BaselineRun) -> Deadlines {
        let wall = max(Double(run.execution.result.nanoseconds) / 1e9, 0.001)
        // With a width set, each suite runs at most that many tests at once, which bounds its parallelism.
        let parallelism = min(max(1, run.suiteCPU / wall), Double(options.suiteWidth ?? Int.max))
        let workers = ChildUsage.workers(
            parallelism: parallelism,
            cores: ProcessInfo.processInfo.activeProcessorCount,
            limit: run.allowedWorkers
        )
        if workers < run.allowedWorkers {
            artifact.notes.append(
                "workers reduced from \(run.allowedWorkers) to \(workers): the suite alone keeps "
                    + "\((parallelism * 10).rounded() / 10) cores busy"
            )
        }
        let derived = Int(run.execution.result.nanoseconds * Int64(options.timeoutFactor) / 1_000_000_000) + 2
        let deadline = min(options.timeoutCap, max(options.minimumTimeout, derived))
        // Parallel workers slow every suite, so a first run gets twice the derived deadline; a rerun runs alone with
        // the same allowance, so contention can no longer cause its timeout.
        let rerun = min(2 * options.timeoutCap, 2 * deadline)
        return Deadlines(
            workers: workers,
            deadline: deadline,
            parallel: workers > 1 ? rerun : deadline,
            rerun: rerun,
            parallelism: parallelism
        )
    }

    func recordPolicy(_ run: BaselineRun, _ limits: Deadlines, flaky: [String]) {
        artifact.policy = RunPolicy(
            harness: run.harness.kind,
            workers: limits.workers,
            failFast: options.failFast,
            killConfirmation: options.killConfirmation,
            deadline: limits.deadline,
            parallelDeadline: limits.parallel,
            timeoutRerunDeadline: limits.rerun,
            baselineNanoseconds: run.execution.result.nanoseconds,
            suiteParallelism: (limits.parallelism * 100).rounded() / 100
        )
        artifact.policy?.memoryLimitMiB = options.memoryLimitMiB > 0 ? options.memoryLimitMiB : nil
        artifact.policy?.background = options.background
        artifact.policy?.baselineRepetitions = run.harness.controlsSwiftTesting ? options.baselineRepetitions : nil
        artifact.policy?.flakyTests = flaky
        artifact.policy?.suiteWidth = options.suiteWidth
        artifact.policy?.operators = options.operators.map(\.rawValue).sorted()
        artifact.policy?.testTargetSelection = run.harness.selectsModules && options.selectTestTargets
    }

    /// The judge every mutant is decided by: baseline counts, deadlines, reused reach, and covering test targets.
    func assembleJudge(_ run: BaselineRun, _ limits: Deadlines, flaky: [String]) throws -> Judge {
        let baselineByModule = run.execution.result.moduleCounts
        var judge = Judge(
            harness: run.harness,
            pool: run.pool,
            options: options,
            counter: counter,
            baseline: run.counts,
            deadline: limits.deadline,
            parallelDeadline: limits.parallel,
            rerunDeadline: limits.rerun
        )
        judge.skip = flaky
        judge.quarantined = Set(quarantined.keys)
        judge.baselineByModule = baselineByModule
        reuseNightlyReach(into: &judge)
        if !options.testTargets.isEmpty {
            guard run.harness.selectsModules else {
                throw LitmusFailure(
                    "--test-target needs a harness that selects test modules (swiftpm-direct or xcodebuild), not \(run.harness.kind)"
                )
            }
            let chosen = try Self.testTargets(options.testTargets, among: Set(baselineByModule.keys))
            for site in toRun { judge.covering[site.id] = chosen }
            artifact.notes.append(
                "every mutant ran only the test targets \(chosen.sorted().joined(separator: ", ")) (--test-target)"
            )
        } else if run.harness.selectsModules, options.selectTestTargets {
            judge.covering = Runner.coveringModules(toRun, root: snapshot.root, modules: Set(baselineByModule.keys))
            artifact.notes.append(
                "test targets selected per mutant from the manifests for \(judge.covering.count) of "
                    + "\(toRun.count) mutants; the others run every test module"
            )
        }
        if !quarantined.isEmpty {
            // Covering targets over every module, quarantined ones included, then without them: an empty set means
            // only quarantined targets cover the mutant.
            let all = Runner.coveringModules(
                toRun,
                root: snapshot.root,
                modules: Set(baselineByModule.keys).union(quarantined.keys)
            )
            for (id, modules) in all { judge.covering[id] = modules.subtracting(quarantined.keys) }
        }
        return judge
    }

    /// The nightly's per-test reach, for the mutants whose key is the same: nothing that could change which tests
    /// reach them changed (t49).
    func reuseNightlyReach(into judge: inout Judge) {
        guard let nightly, nightly.reuse?.mode == .closure, let reach = nightly.perTestReach,
            let counts = nightly.testCounts
        else { return }
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

    /// The test module whose failure ended `result`: the harness's, else the module of its first failing test.
    static func failedModule(_ result: TestRunResult) -> String? {
        if let module = result.failedModule { return module }
        guard let test = result.failingTests.first, let dot = test.firstIndex(of: ".") else { return nil }
        return String(test[..<dot])
    }

    /// The modules `requested` names among those the baseline ran; a SwiftPM spelling and an Xcode target name both
    /// match. Unknown names are an error that lists the known ones.
    static func testTargets(_ requested: [String], among known: Set<String>) throws -> Set<String> {
        var chosen: Set<String> = []
        for name in requested {
            guard let found = [name, Runner.moduleName(name)].first(where: known.contains) else {
                throw LitmusFailure(
                    "--test-target \(name) is not a test target of this run; known: \(known.sorted().joined(separator: ", "))"
                )
            }
            chosen.insert(found)
        }
        return chosen
    }
}
