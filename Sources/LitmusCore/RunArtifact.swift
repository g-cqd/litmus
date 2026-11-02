/// How a run was executed; part of provenance, so two runs with different policies are never compared as equal.
public struct RunPolicy: Codable, Sendable, Equatable {
    /// `swiftpm-direct`, `swift-test` or `xcodebuild`.
    public let harness: String
    public let workers: Int
    public let failFast: Bool
    public let killConfirmation: KillConfirmation
    /// The per-suite deadline derived from the baseline, in seconds, and the rerun deadline for timeouts.
    public let deadline: Int
    /// The deadline of a mutant's first run among parallel workers (twice `deadline` with more than one worker).
    public let parallelDeadline: Int
    public let timeoutRerunDeadline: Int
    /// The unmutated suite's duration, in nanoseconds.
    public let baselineNanoseconds: Int64
    /// Cores the suite keeps busy alone (child CPU ÷ wall time), which sized `workers`.
    public let suiteParallelism: Double
    /// The memory limit of a test process and what it starts, in MiB; nil without one (and before 0.3).
    public var memoryLimitMiB: Int? = nil
    /// Whether builds and first runs ran at background priority.
    public var background: Bool? = nil
    /// Repetitions of the unmutated suite that looked for flaky tests, and the tests found and left out.
    public var baselineRepetitions: Int? = nil
    public var flakyTests: [String]? = nil
    /// The most Swift Testing tests a suite ran at once, when set.
    public var suiteWidth: Int? = nil
    /// Whether each mutant ran only the test targets that can reach its file.
    public var testTargetSelection: Bool? = nil
    /// Which build the baseline ran on: `inactive-schema` or `unmutated` (ADR 0007); nil before 0.3.
    public var baselineBuild: String? = nil
}

/// The limits a run was given, and what they left untested.
public struct BudgetRecord: Codable, Sendable, Equatable {
    public var seconds: Int?
    public var maxMutants: Int?
    /// `time` or `max-mutants` when a limit was reached; nil when everything ran.
    public var stoppedBy: String? = nil
    /// The mutants left `notRun` by a limit: not a failure and not a pass; the gate judges what ran.
    public var untested: [String] = []

    public init(seconds: Int? = nil, maxMutants: Int? = nil) {
        self.seconds = seconds
        self.maxMutants = maxMutants
    }
}

/// How verdicts were reused (ADR 0007).
public struct ReuseRecord: Codable, Sendable, Equatable {
    public let mode: ReuseContext.Mode
    /// The digest of the run's verdict-relevant options, toolchain and policy (part of every key).
    public let context: String
    public let store: String?
    public let storeReadOnly: Bool?
    public let resumedFrom: String?
    public let resumed: Int
    public let fromStore: Int
}

/// Provenance required before a verdict may be presented as current execution evidence.
public struct RunProvenance: Codable, Sendable {
    public let toolVersion: String
    public let snapshotSHA256: String
    public let inputs: [SnapshotEntry]
    public let driver: BuildDriver
    public let toolchain: String
    public let startedAt: String
    public let executionPolicy: String

    /// The run's identity: when it started and the first 12 digits of its snapshot digest.
    public var runID: String { "\(startedAt) \(snapshotSHA256.prefix(12))" }
}

/// One decision with the test evidence and explanation that justified it.
public struct MutationResult: Codable, Sendable {
    public let mutation: Mutation
    public let verdict: Verdict
    public let tests: TestCounts?
    public let reason: String
    public let evidence: [String]
    /// Test time spent on this mutant, in nanoseconds, reruns included; zero when it never ran.
    public let nanoseconds: Int64
    /// The key the verdict is stored and found under (`ReuseContext`); nil when the run had no reuse context.
    public var reuseKey: String? = nil
    /// The run that decided this verdict when it was reused rather than tested now (`RunProvenance.runID`), with the
    /// reuse mode when not the sound one; nil for a verdict decided by this run.
    public var reusedFrom: String? = nil

    public init(
        mutation: Mutation,
        verdict: Verdict,
        tests: TestCounts? = nil,
        reason: String,
        evidence: [String] = [],
        nanoseconds: Int64 = 0
    ) {
        self.mutation = mutation
        self.verdict = verdict
        self.tests = tests
        self.reason = reason
        self.evidence = evidence
        self.nanoseconds = nanoseconds
    }
}

/// The record of a run. `complete` never means that infrastructure errors were kills.
public struct RunArtifact: Codable, Sendable {
    public static let executionPolicy = "activation-markers/no-coverage/unviable-isolation/inactive-schema-baseline/v4"
    public let version: Int
    public let provenance: RunProvenance
    public let plan: MutationPlan
    public var policy: RunPolicy?
    public var complete: Bool
    public var results: [MutationResult]
    public var notes: [String]
    /// Seconds per phase.
    public var timings: [String: Double]
    /// With `--per-test-reach`: for each reached mutant, the Swift Testing tests that reach it when run alone (no
    /// mutant active), and each test's duration alone in nanoseconds. Nil otherwise.
    public var perTestReach: [String: [String]]? = nil
    public var testNanoseconds: [String: Int64]? = nil
    /// What the run cost the machine (wall, CPU, peak memory, disk, builds, test runs).
    public var cost: RunCost? = nil
    /// The limits given (`--budget`, `--max-mutants`) and what they left untested; nil without limits.
    public var budget: BudgetRecord? = nil
    /// How verdicts were reused; nil before 0.3.
    public var reuse: ReuseRecord? = nil
    /// The score over the mutants that were decided: a budget's untested mutants are outside it, not undetected.
    public var score: MutationScore {
        let untested = Set(budget?.untested ?? [])
        return MutationScore(results.filter { !untested.contains($0.mutation.id) }.map(\.verdict))
    }

    public init(provenance: RunProvenance, plan: MutationPlan) {
        version = 2
        self.provenance = provenance
        self.plan = plan
        policy = nil
        complete = false
        results = plan.mutations.map { MutationResult(mutation: $0, verdict: .notRun, reason: "not executed yet") }
        notes = []
        timings = [:]
    }

    /// Only a complete, reconciled run whose every verdict is resolved may pass an execution gate.
    public var isSuccessfulExecution: Bool {
        complete && !plan.notes.contains(where: \.isDegraded)
            && results.count == plan.mutations.count
            && Set(results.map { $0.mutation.id }).count == results.count
            && Set(results.map { $0.mutation.id }) == Set(plan.mutations.map(\.id))
            && results.allSatisfy { $0.verdict.isResolved || budgetLeftUntested($0) }
    }

    /// A mutant a budget left untested: `notRun` and listed in ``budget``.
    public func budgetLeftUntested(_ result: MutationResult) -> Bool {
        result.verdict == .notRun && (budget?.untested.contains(result.mutation.id) ?? false)
    }
}
