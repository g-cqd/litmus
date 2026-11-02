/// How a run was executed; part of provenance, so two runs with different policies are never compared as equal.
public struct RunPolicy: Codable, Sendable, Equatable {
    /// `swiftpm-direct`, `swift-test` or `xcodebuild`.
    public let harness: String
    public let workers: Int
    public let failFast: Bool
    public let confirmKills: Bool
    /// The per-suite deadline derived from the baseline, in seconds, and the rerun deadline for timeouts.
    public let deadline: Int
    public let timeoutRerunDeadline: Int
    /// The unmutated suite's duration, in nanoseconds.
    public let baselineNanoseconds: Int64
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
    public static let executionPolicy = "activation-markers/no-coverage/unviable-isolation/v2"
    public let version: Int
    public let provenance: RunProvenance
    public let plan: MutationPlan
    public var policy: RunPolicy?
    public var complete: Bool
    public var results: [MutationResult]
    public var notes: [String]
    /// Seconds per phase.
    public var timings: [String: Double]
    public var score: MutationScore { MutationScore(results.map(\.verdict)) }

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
            && results.allSatisfy(\.verdict.isResolved)
    }
}
