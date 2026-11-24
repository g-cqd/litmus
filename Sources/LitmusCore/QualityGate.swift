/// Numeric limits on a run's mutation score, judged after the run.
///
/// An unresolved mutant (an infrastructure error, a mutant not run outside a budget) always fails a run, so there is no
/// separate limit on those. A score is only compared with another run's when both measured the same thing.
public struct QualityGate: Sendable {
    /// The lowest score that passes, as a percentage.
    public var minimumScore: Double?
    /// The largest fall from the baseline run's score that passes, in percentage points.
    public var maximumScoreDrop: Double?
    /// The earlier run the drop is measured against.
    public var baseline: RunArtifact?

    public init(minimumScore: Double? = nil, maximumScoreDrop: Double? = nil, baseline: RunArtifact? = nil) {
        self.minimumScore = minimumScore
        self.maximumScoreDrop = maximumScoreDrop
        self.baseline = baseline
    }

    public var isEmpty: Bool { minimumScore == nil && maximumScoreDrop == nil }

    /// What of a run its score depends on.
    struct Measured: Equatable {
        var score: MutationScore
        var operators: Set<String>
        var files: Set<String>
        var scoped: Bool
        var sharded: Bool
        var budgeted: Bool

        init(_ artifact: RunArtifact) {
            score = artifact.score
            operators = Set(artifact.policy?.operators ?? MutationOperator.defaults.map(\.rawValue))
            files = Set(artifact.plan.mutations.map(\.path))
            scoped = artifact.plan.scope != nil
            sharded = artifact.shard != nil
            budgeted = artifact.budget?.stoppedBy != nil
        }

        init(score: MutationScore, operators: Set<String>, files: Set<String>) {
            self.score = score
            self.operators = operators
            self.files = files
            scoped = false
            sharded = false
            budgeted = false
        }
    }

    /// Why `artifact` fails the gate; empty when it passes.
    public func failures(for artifact: RunArtifact) -> [String] {
        failures(for: Measured(artifact), baseline: baseline.map(Measured.init))
    }

    func failures(for run: Measured, baseline: Measured?) -> [String] {
        guard !isEmpty else { return [] }
        let score = run.score
        var failures: [String] = []
        // A run that decided nothing (no site in scope, or only unviable ones) has no score to judge.
        let measured = score.detected + score.undetected > 0
        if score.unresolved > 0 {
            failures.append("\(score.unresolved) mutant(s) have no resolved verdict, so there is no score to judge")
            return failures
        }
        if let minimumScore, measured, let percent = score.percent, percent < minimumScore {
            failures.append(
                "mutation score \(Self.format(percent)) % is below the minimum \(Self.format(minimumScore)) %"
            )
        }
        if let maximumScoreDrop {
            guard let baseline else {
                failures.append("--maximum-score-drop needs --baseline-run, an earlier run to compare with")
                return failures
            }
            if let reason = Self.incomparable(run, baseline) {
                failures.append("the score cannot be compared with the baseline run's: \(reason)")
            } else if let now = score.percent, let before = baseline.score.percent, before - now > maximumScoreDrop {
                failures.append(
                    "mutation score fell \(Self.format(before - now)) points (from \(Self.format(before)) % to \(Self.format(now)) %); at most \(Self.format(maximumScoreDrop)) allowed"
                )
            } else if score.percent == nil || baseline.score.percent == nil {
                failures.append("the baseline run or this run has no score, so the drop cannot be judged")
            }
        }
        return failures
    }

    /// Why two runs' scores do not measure the same thing, or nil when they do: both whole-subject runs of the same
    /// operators over the same files.
    static func incomparable(_ lhs: Measured, _ rhs: Measured) -> String? {
        if lhs.scoped || rhs.scoped { return "a run limited to a change measures only that change" }
        if lhs.sharded || rhs.sharded { return "a shard measures only part of the subject" }
        if lhs.budgeted || rhs.budgeted { return "a budget left mutants untested" }
        if lhs.operators != rhs.operators { return "the two runs mutated different operators" }
        if lhs.files != rhs.files { return "the two runs mutated different files" }
        return nil
    }

    static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String((value * 100).rounded() / 100)
    }
}
