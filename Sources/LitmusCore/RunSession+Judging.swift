internal import AemiRuntime
internal import Foundation

extension RunSession {
    /// `sites` with the slowest first, by what each cost before; sites without history keep their order, after those
    /// with it. Workers that start the long runs first finish together instead of waiting on one straggler.
    static func longestFirst(_ sites: [Mutation], hints: [String: Int64]) -> [Mutation] {
        sites.enumerated().sorted { lhs, rhs in
            let (left, right) = (hints[lhs.element.id] ?? 0, hints[rhs.element.id] ?? 0)
            return left != right ? left > right : lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// The mutants of `group` the control reached; the rest are recorded (no coverage, or only quarantined targets
    /// cover them). Seeds the judge's timings and the shared-process decision from the control.
    func cover(
        _ group: inout [Mutation],
        control: Judge.Execution,
        judge: inout Judge,
        workers: Int
    ) throws -> [Mutation] {
        // Mutants only quarantined targets cover: no run can decide them, and the control never ran those targets.
        let unjudgeable = group.filter { judge.covering[$0.id]?.isEmpty == true }
        if !unjudgeable.isEmpty {
            try runner.untested(
                unjudgeable,
                "covering test target(s) \(quarantined.keys.sorted().joined(separator: ", ")) failed unmutated",
                stoppedBy: "failing-test-target",
                into: &artifact,
                sink
            )
            let skipped = Set(unjudgeable.map(\.id))
            group.removeAll { skipped.contains($0.id) }
        }
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
        // The control ran every bundle once, fresh: its average per-bundle time bounds a narrowed run (at most one
        // bundle's start + its tests) from the very first mutant, even when shared workers handle the fast ones.
        if control.result.outcome == .passed, control.result.nanoseconds > 0 {
            let perBundle = control.result.nanoseconds / Int64(max(1, judge.baselineByModule.count))
            judge.timings.seed(nanoseconds: max(perBundle, 1), kind: "tests")
        }
        if let shared = judge.harness as? any SharedProcessControl {
            // Per bundle: the control ran every module once, fresh; what its tests did not take is process start.
            let bundles = Int64(max(1, shared.bundleCount))
            let tests = control.result.testDurations.values.reduce(0, +)
            let wall = control.result.nanoseconds
            if let note = shared.decide(
                covered: covered.count,
                workers: workers,
                suiteNanoseconds: wall / bundles,
                spawnNanoseconds: max(0, wall - tests) / bundles
            ) {
                artifact.notes.append(note)
            }
        }
        return covered
    }

    /// Per-test reach for `covered`: from the control's event stream when Swift Testing reports per test, else by
    /// running each test function alone. This schema's reach decides its mutants: selection and the kill check.
    func collectReach(
        _ covered: [Mutation],
        control: Judge.Execution,
        established current: Established,
        judge: inout Judge,
        name: String,
        perTestCounts: inout [String: TestCounts]
    ) async throws {
        guard options.perTestReach, judge.harness.selectsTests, !covered.isEmpty else { return }
        let ids = Set(covered.map(\.id))
        var reach: [String: [String]] = artifact.perTestReach ?? [:]
        var durations: [String: Int64] = artifact.testNanoseconds ?? [:]
        if judge.harness.controlsSwiftTesting, !control.result.perTestCounts.isEmpty {
            // Single-pass per-test reach from the serial control run's interleaved FIFO event stream: 1 run instead
            // of O(T) runs, excluding sites reached outside any test boundary (`static let` / launch).
            perTestCounts.merge(control.result.perTestCounts) { _, new in new }
            for (test, nanos) in control.result.testDurations {
                durations[test] = max(durations[test] ?? 0, nanos)
            }
            let outside = control.result.outsideTests
            for id in ids where !outside.contains(id) {
                if let tests = control.result.perTestReach[id], !tests.isEmpty {
                    var merged = Set(reach[id] ?? [])
                    merged.formUnion(tests)
                    reach[id] = merged.sorted()
                }
            }
        } else if !current.testFunctions.isEmpty {
            let runs = Array(current.testFunctions.enumerated())
            let probing = judge
            let deadline = current.deadline
            try await forEachConcurrently(
                runs,
                limit: current.workerCount,
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
                    artifact.notes.append("per-test reach: \(test) did not pass alone (\(execution.result.reason))")
                    return
                }
                durations[test] = max(durations[test] ?? 0, execution.result.nanoseconds)
                if let counts = execution.result.counts { perTestCounts[test] = counts }
                for id in execution.reached.intersection(ids) { reach[id, default: []].append(test) }
            }
        }
        artifact.perTestReach = reach.mapValues { $0.sorted() }
        artifact.testNanoseconds = durations
        artifact.testCounts = perTestCounts
        for site in covered {
            if let tests = reach[site.id], !tests.isEmpty {
                judge.reach[site.id] = Set(tests)
            }
        }
    }

    /// Decides every covered mutant: first runs in parallel, targeted kill confirmation, serial reruns, and the
    /// recheck of narrowed survivors. Each decision is journalled as it comes (aemi's `forEachConcurrently`): a crash
    /// of Litmus loses only the runs in flight.
    func decide(_ covered: [Mutation], judge: Judge, workers: Int, name: String) async throws {
        let budgetEnd = self.budgetEnd
        let deciding = judge
        var reruns: [Judge.Pending] = []
        // Narrowed survivors wait for `recheck` before being recorded.
        var narrowedSurvivors: [Judge.Decision] = []
        var late: [Mutation] = []
        try await forEachConcurrently(
            Self.longestFirst(covered, hints: durationHints),
            limit: workers,
            { site in
                if let budgetEnd, ContinuousClock.now >= budgetEnd { return Judge.Step.notStarted(site) }
                return try await deciding.first(site)
            }
        ) { _, step in
            switch step {
            case .done(let decision): try keep(decision, judge: deciding, narrowed: &narrowedSurvivors)
            case .rerun(let pending): reruns.append(pending)
            case .notStarted(let site): late.append(site)
            }
        }
        let targeted = reruns.filter { deciding.canConfirmTargeted($0) }
        var serialReruns = reruns.filter { !deciding.canConfirmTargeted($0) }
        if !targeted.isEmpty {
            try await confirmTargeted(
                targeted,
                judge: deciding,
                workers: workers,
                name: name,
                serial: &serialReruns,
                late: &late
            )
        }
        for pending in serialReruns {
            if let budgetEnd, clock.now >= budgetEnd {
                late.append(pending.site)
                continue
            }
            try keep(try await judge.finish(pending), judge: deciding, narrowed: &narrowedSurvivors)
        }
        if !narrowedSurvivors.isEmpty {
            var unnarrowed = judge
            unnarrowed.reach = [:]
            try await recheck(narrowedSurvivors, judge: unnarrowed, workers: workers, late: &late)
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
    }

    /// Records `decision`, or holds it back when it is a narrowed survivor that `--recheck-survivors` reruns.
    func keep(_ decision: Judge.Decision, judge: Judge, narrowed: inout [Judge.Decision]) throws {
        if options.recheckSurvivors, decision.verdict == .survived, judge.selected(decision.site) != nil {
            narrowed.append(decision)
        } else {
            try runner.record(decision, into: &artifact, sink)
        }
    }
}
