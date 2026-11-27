import Foundation
import Testing

@testable import LitmusCore

@Suite struct CIScaleTests {
    /// A plan over one heavy and one light module, and a completed run of it with `verdict(mutation)`.
    static func run(_ verdict: (Mutation) -> Verdict) async throws -> (MutationPlan, RunArtifact, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("litmus-ci-\(UUID().uuidString)").path
        for module in ["Big", "Small"] {
            try FileManager.default.createDirectory(
                atPath: root + "/Sources/\(module)",
                withIntermediateDirectories: true
            )
        }
        try Data("func a(_ x: Int) -> Bool { x < 1 && x > 0 && x <= 5 && x >= 2 }\n".utf8)
            .write(to: URL(fileURLWithPath: root + "/Sources/Big/A.swift"))
        try Data("func b(_ x: Int) -> Bool { x < 1 }\n".utf8)
            .write(to: URL(fileURLWithPath: root + "/Sources/Small/B.swift"))
        let plan = try await MutationPlanner.plan(root: root, operators: [.replaceRelational])
        let entries = try await WorkspaceSnapshot.currentEntries(root)
        var artifact = RunArtifact(
            provenance: RunProvenance(
                toolVersion: LitmusVersion.current,
                snapshotSHA256: Digest.sha256(try ArtifactCodec.json(entries)),
                inputs: entries,
                driver: try BuildDriver(root: root, scheme: nil, destination: nil),
                toolchain: "test",
                startedAt: "2026-11-27T00:00:00Z",
                executionPolicy: RunArtifact.executionPolicy
            ),
            plan: plan
        )
        artifact.complete = true
        artifact.results = plan.mutations.map {
            MutationResult(mutation: $0, verdict: verdict($0), reason: "every test passed", nanoseconds: 1)
        }
        return (plan, artifact, root)
    }

    @Test func `mutant sharding balances mutants where module sharding cannot`() async throws {
        let (plan, _, root) = try await Self.run { _ in .survived }
        defer { try? FileManager.default.removeItem(atPath: root) }
        var byMutant = [try ShardSelection(index: 1, count: 2), try ShardSelection(index: 2, count: 2)]
        for index in byMutant.indices { byMutant[index].strategy = .mutant }
        let mutantShards = byMutant.map { Sharding.select(plan, $0).0.mutations.count }
        let moduleShards = [1, 2].map {
            Sharding.select(plan, try! ShardSelection(index: $0, count: 2)).0.mutations.count
        }
        #expect(mutantShards.reduce(0, +) == plan.mutations.count)
        #expect(abs(mutantShards[0] - mutantShards[1]) <= 1)
        #expect(abs(moduleShards[0] - moduleShards[1]) > 1)
        let ids = byMutant.map { Set(Sharding.select(plan, $0).0.mutations.map(\.id)) }
        #expect(ids[0].isDisjoint(with: ids[1]))
    }

    @Test func `the step summary shows score changes, regressions and a diff per survivor`() async throws {
        let (_, before, root) = try await Self.run { _ in .killed }
        defer { try? FileManager.default.removeItem(atPath: root) }
        var now = before
        let survivor = try #require(now.results.first)
        now.results[0] = MutationResult(
            mutation: survivor.mutation,
            verdict: .survived,
            reason: "every test passed <after> the mutant ran",
            nanoseconds: 1
        )
        let summary = GitHubSummaryReport.render(now, previous: before)
        #expect(summary.contains("pts)"))
        #expect(summary.contains("### Detected before, undetected now (1)"))
        #expect(summary.contains("### Survivors (1)"))
        #expect(summary.contains("<details><summary><code>\(survivor.mutation.path):\(survivor.mutation.line)</code>"))
        #expect(summary.contains("- \(survivor.mutation.original)"))
        #expect(summary.contains("+ \(survivor.mutation.replacement)"))
        #expect(summary.contains("&lt;after&gt;"))
        #expect(!GitHubSummaryReport.render(before).contains("<details>"))
    }
}
