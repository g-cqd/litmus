internal import Foundation

extension Judge {
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
