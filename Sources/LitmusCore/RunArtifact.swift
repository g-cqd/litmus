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

    public init(mutation: Mutation, verdict: Verdict, tests: TestCounts? = nil, reason: String, evidence: [String] = []) {
        self.mutation = mutation; self.verdict = verdict; self.tests = tests; self.reason = reason; self.evidence = evidence
    }
}

/// Checkpointed execution record. `complete` never means that infrastructure errors were kills.
public struct RunArtifact: Codable, Sendable {
    public let version: Int
    public let provenance: RunProvenance
    public let plan: MutationPlan
    public var complete: Bool
    public var results: [MutationResult]
    public var notes: [String]

    public init(provenance: RunProvenance, plan: MutationPlan) {
        version = 1; self.provenance = provenance; self.plan = plan; complete = false
        results = plan.mutations.map { MutationResult(mutation: $0, verdict: .notRun, reason: "not executed yet") }
        notes = []
    }

    /// Only a fully reconciled, baseline-valid run with no unresolved outcomes is eligible for a green execution gate.
    public var isSuccessfulExecution: Bool {
        complete && !plan.notes.contains(where: \.isDegraded) &&
            results.count == plan.mutations.count &&
            Set(results.map { $0.mutation.id }).count == results.count &&
            Set(results.map { $0.mutation.id }) == Set(plan.mutations.map(\.id)) &&
            results.allSatisfy { [.killed, .survived].contains($0.verdict) }
    }
}
