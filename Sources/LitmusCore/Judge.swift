internal import AemiIO
internal import AemiJSON
internal import AemiRuntime
internal import Foundation
internal import ProjectModel
internal import SourceCorpus

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
    /// For each mutant whose per-test reach is known (this run's `--per-test-reach`, or a matching `--reach-from`):
    /// the Swift Testing tests that reach it when run alone, no mutant active (t37, t38).
    var reach: [String: Set<String>] = [:]
    /// Each test's counts when it ran alone (with per-test reach): what a run of selected tests must pass.
    var testCounts: [String: TestCounts] = [:]

    /// The reaching tests a mutant's runs are limited to: known, not empty, every count known; nil runs the modules.
    func selected(_ site: Mutation) -> [String]? {
        guard harness.selectsTests, let tests = reach[site.id], !tests.isEmpty,
            tests.allSatisfy({ testCounts[$0] != nil })
        else { return nil }
        return tests.sorted()
    }

    /// The counts a passing run of `site` must have: its reaching tests', its selected modules', or the baseline's.
    func expected(_ site: Mutation) -> TestCounts {
        if let tests = selected(site) {
            var passed = 0, skipped = 0
            for test in tests {
                passed += testCounts[test]?.passed ?? 0
                skipped += testCounts[test]?.skipped ?? 0
            }
            return TestCounts(passed: passed, failed: 0, skipped: skipped)
        }
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
        alone: Bool = false,
        collectPerTestReach: Bool = false
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
        request.collectPerTestReach = collectPerTestReach
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
        // Every run of a mutant uses the same tests: its reaching ones when selected, so counts compare.
        let execution = try await execute(
            name: "mutant-\(site.id)\(suffix)",
            activeID: active ? site.id : "",
            deadline: deadline,
            failFast: active && options.failFast,
            only: only ?? selected(site),
            modules: covering[site.id],
            alone: !suffix.isEmpty
        )
        ledger.evidence += execution.result.evidence
        ledger.nanoseconds += execution.result.nanoseconds
        return execution
    }

    /// Whether per-test reach rejects a failure: it is known for the mutant, the failing tests are named, and none of
    /// them reaches the mutant (the fcheck timing test's false kills, study 4).
    func reachRejects(_ site: Mutation, failing: [String]) -> Bool {
        guard let tests = reach[site.id], !failing.isEmpty else { return false }
        return tests.isDisjoint(with: failing)
    }

    /// The first run of one reached mutant, among the parallel workers, with `parallelDeadline`. With its per-test
    /// reach known, only the reaching tests run, in one process.
    func first(_ site: Mutation) async throws -> Step {
        var ledger = Ledger(site: site, baseline: expected(site), evidence: [], nanoseconds: 0)
        let first = try await run(site, "", active: true, deadline: parallelDeadline, ledger: &ledger)
        let activated = first.reached.contains(site.id)
        switch first.result.outcome {
        case .passed: return .done(ledger.passing(first))
        case .unusable: return .done(ledger.decision(.infrastructureError, first.result.reason))
        case .failed
        where activated && options.killConfirmation == .none
            && !reachRejects(site, failing: first.result.failingTests):
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

    /// Whether `pending` can be confirmed by running only its failing tests (`-confirm` + a control for those tests)
    /// concurrently across workers before any serial alone-reruns.
    func canConfirmTargeted(_ pending: Pending) -> Bool {
        pending.outcome == .failed && pending.activated && options.killConfirmation == .targeted
            && reach[pending.site.id] == nil && harness.selectsTests && !pending.failingTests.isEmpty
    }

    /// Confirms a targeted kill by running only `pending.failingTests` with the mutant active, and checking that the
    /// same tests pass without the mutant (skipping the control run when `verifiedControls` already proved those exact
    /// tests pass alone on this schema). Returns nil when the failure did not reproduce so the caller falls back to a
    /// serial whole-suite rerun alone.
    /// The single failing test used to confirm `pending` quickly; deduplicates control checks across mutants killed
    /// by the same test.
    static func confirmingTests(for pending: Pending) -> [String]? {
        pending.failingTests.first.map { [$0] }
    }

    func confirmTargeted(_ pending: Pending, verifiedControls: Set<[String]>) async throws -> Decision? {
        guard let tests = Self.confirmingTests(for: pending) else { return nil }
        let site = pending.site
        var ledger = Ledger(
            site: site,
            baseline: expected(site),
            evidence: pending.evidence,
            nanoseconds: pending.nanoseconds
        )
        let active = try await run(
            site,
            "-confirm",
            active: true,
            deadline: parallelDeadline,
            only: tests,
            ledger: &ledger
        )
        guard active.result.outcome == .failed, active.reached.contains(site.id) else { return nil }
        if !verifiedControls.contains(tests) {
            let control = try await run(
                site,
                "-control",
                active: false,
                deadline: parallelDeadline,
                only: tests,
                ledger: &ledger
            )
            guard control.result.outcome == .passed else { return nil }
        }
        let killers = active.result.failingTests.isEmpty ? tests : active.result.failingTests
        return ledger.decision(.killed, "killed by \(killers.joined(separator: ", ")), confirmed alone")
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
        if pending.outcome == .failed, pending.activated, let tests = reach[site.id], !pending.failingTests.isEmpty {
            // Per-test reach decides without reruns (t37): each reaching test passed alone with no mutant active and
            // reached this one; a failing test among them is a kill. None among them: not the mutant's doing, and the
            // whole suite, alone, decides below.
            let killers = pending.failingTests.filter(tests.contains)
            if !killers.isEmpty {
                return ledger.decision(
                    .killed,
                    "killed by \(killers.joined(separator: ", ")), which reach the mutant (per-test reach)"
                )
            }
        } else if pending.outcome == .failed, pending.activated, harness.selectsTests, !pending.failingTests.isEmpty {
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
