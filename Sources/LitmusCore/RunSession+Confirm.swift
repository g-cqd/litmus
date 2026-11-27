internal import AemiRuntime
internal import Foundation

extension RunSession {
    /// Confirms kills by rerunning only the failing tests. Each unique set of failing tests is verified once on this
    /// schema with no mutant active: many mutants are killed by the same test, so repeating the identical inactive
    /// control run adds no evidence. What cannot be confirmed this way goes to `serial`.
    func confirmTargeted(
        _ targeted: [Judge.Pending],
        judge deciding: Judge,
        workers: Int,
        name: String,
        serial: inout [Judge.Pending],
        late: inout [Mutation]
    ) async throws {
        let budgetEnd = self.budgetEnd
        let uniqueTestSets = Array(Set(targeted.compactMap(Judge.confirmingTests))).sorted {
            $0.joined(separator: "\0") < $1.joined(separator: "\0")
        }
        var verifiedControls: Set<[String]> = []
        try await forEachConcurrently(
            Array(uniqueTestSets.enumerated()),
            limit: workers,
            { pair -> Bool in
                if let budgetEnd, ContinuousClock.now >= budgetEnd { return false }
                let control = try await deciding.execute(
                    name: "\(name)-confirm-control-\(pair.offset)",
                    activeID: "",
                    deadline: deciding.parallelDeadline,
                    only: pair.element
                )
                return control.result.outcome == .passed
            }
        ) { index, passed in
            if passed { verifiedControls.insert(uniqueTestSets[index]) }
        }
        let controls = verifiedControls
        try await forEachConcurrently(
            targeted,
            limit: workers,
            { pending -> (Judge.Pending, Judge.Decision?, Bool) in
                if let budgetEnd, ContinuousClock.now >= budgetEnd { return (pending, nil, true) }
                let decision = try await deciding.confirmTargeted(pending, verifiedControls: controls)
                return (pending, decision, false)
            }
        ) { _, outcome in
            let (pending, decision, outOfBudget) = outcome
            if outOfBudget {
                late.append(pending.site)
            } else if let decision {
                try runner.record(decision, into: &artifact, sink)
            } else {
                serial.append(pending)
            }
        }
    }

    /// Soundness check for per-test reach narrowing: re-runs survivors against the full covering modules so
    /// cross-test shared state or XCTest cases can still detect the mutant.
    func recheck(
        _ narrowedSurvivors: [Judge.Decision],
        judge fullJudge: Judge,
        workers: Int,
        late: inout [Mutation]
    ) async throws {
        let budgetEnd = self.budgetEnd
        var recheckReruns: [Judge.Pending] = []
        try await forEachConcurrently(
            narrowedSurvivors,
            limit: workers,
            { prior -> (Judge.Decision, Judge.Step?) in
                if let budgetEnd, ContinuousClock.now >= budgetEnd { return (prior, nil) }
                return (prior, try await fullJudge.first(prior.site))
            }
        ) { _, pair in
            let (prior, step) = pair
            guard let step else {
                try runner.record(prior, into: &artifact, sink)
                return
            }
            switch step {
            case .done(let full): try runner.record(full, into: &artifact, sink)
            case .rerun(let pending): recheckReruns.append(pending)
            case .notStarted: try runner.record(prior, into: &artifact, sink)
            }
        }
        for pending in recheckReruns {
            if let budgetEnd, clock.now >= budgetEnd {
                late.append(pending.site)
                continue
            }
            try runner.record(try await fullJudge.finish(pending), into: &artifact, sink)
        }
    }
}
