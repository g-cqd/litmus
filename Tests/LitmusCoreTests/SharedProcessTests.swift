import Foundation
import Testing

@testable import LitmusCore

#if os(macOS)
    /// The equivalence oracle of shared-process execution (docs/design/shared-process.md): on a package with a
    /// `static let` from a mutated expression, a `lazy var` on a singleton, a mutant that corrupts a global before its
    /// test fails, and mutants that trap, `--shared-process on` gives every mutant the verdict an isolated run gives.
    @Suite(.serialized) struct SharedProcessTests {
        private func run(shared: Bool, fixture: String, root: URL) async throws -> RunArtifact {
            let package = root.appendingPathComponent(shared ? "shared" : "isolated")
            try FileManager.default.copyItem(atPath: fixture, toPath: package.path)
            var options = RunOptions()
            options.operators = [
                .negateCondition, .swapTernary, .replaceRelational, .flipBoolean, .replaceArithmetic, .removeCall,
                .returnBoundary, .returnConstant,
            ]
            options.baselineRepetitions = 1
            options.jobs = 4
            options.sharedProcess = shared ? .on : .off
            return try await MutationRunner(executor: BoundedExecutor()).run(
                driver: try BuildDriver(root: package.path, scheme: nil, destination: nil),
                outputDirectory: root.appendingPathComponent(shared ? "shared-run" : "isolated-run").path,
                options: options
            )
        }

        @Test(.timeLimit(.minutes(10))) func `shared-process verdicts equal isolated verdicts, mutant by mutant`()
            async throws
        {
            let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Fixtures/SharedProcess").path
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("litmus-d1-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let isolated = try await run(shared: false, fixture: fixture, root: root)
            let shared = try await run(shared: true, fixture: fixture, root: root)
            #expect(isolated.isSuccessfulExecution && shared.isSuccessfulExecution)
            let expected = Dictionary(uniqueKeysWithValues: isolated.results.map { ($0.mutation.id, $0.verdict) })
            let actual = Dictionary(uniqueKeysWithValues: shared.results.map { ($0.mutation.id, $0.verdict) })
            #expect(actual == expected)
            #expect(Set(expected.values).isSuperset(of: [.killed, .survived, .crashed, .noCoverage]))
            // Kills were decided in shared workers, and the static let and lazy var paths were kept out of them.
            let note = try #require(shared.notes.first { $0.hasPrefix("shared process: ") && $0.contains("kill(s)") })
            #expect(!note.hasPrefix("shared process: 0 kill(s)"))
            let staticLet = try #require(shared.results.first { $0.mutation.original == "isStrict(3)" })
            #expect(staticLet.verdict == .killed)
            #expect(!staticLet.evidence.contains { $0.contains("-shared.events") })
            let lazy = shared.results.filter { $0.mutation.original == "base * 2" }
            #expect(!lazy.isEmpty && lazy.allSatisfy { !$0.evidence.contains { $0.contains("-shared.events") } })
        }

        @Test(.timeLimit(.minutes(10))) func `auto stays off where processes start fast, with the isolated verdicts`()
            async throws
        {
            // WalletKit: a static let, a lazy var, a locked process-wide audit trail, equivalent clamps.
            let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("bench/Transit/Modules/WalletKit").path
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("litmus-d1a-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let isolated = try await run(mode: .off, fixture: fixture, root: root)
            let auto = try await run(mode: .auto, fixture: fixture, root: root)
            let expected = Dictionary(uniqueKeysWithValues: isolated.results.map { ($0.mutation.id, $0.verdict) })
            let actual = Dictionary(uniqueKeysWithValues: auto.results.map { ($0.mutation.id, $0.verdict) })
            #expect(actual == expected)
            // A SwiftPM bundle on macOS starts in about 0.1 s: below the threshold, so no worker starts.
            #expect(auto.notes.contains { $0.hasPrefix("shared process (auto): off for ") })
            #expect(!auto.notes.contains { $0.hasPrefix("shared process: ") })
        }

        private func run(mode: SharedProcessMode, fixture: String, root: URL) async throws -> RunArtifact {
            let package = root.appendingPathComponent(mode.rawValue)
            try FileManager.default.copyItem(atPath: fixture, toPath: package.path)
            var options = RunOptions()
            options.operators = Set(MutationOperator.allCases).filter { $0.tier != .experimental }
            options.baselineRepetitions = 1
            options.jobs = 4
            options.sharedProcess = mode
            return try await MutationRunner(executor: BoundedExecutor()).run(
                driver: try BuildDriver(root: package.path, scheme: nil, destination: nil),
                outputDirectory: root.appendingPathComponent(mode.rawValue + "-run").path,
                options: options
            )
        }
    }
#endif

@Test func `auto engages when the process starts it saves exceed what the workers cost`() {
    let second: Int64 = 1_000_000_000
    // Fewer than 8 covered mutants: never.
    #expect(
        !SharedProcessHarness<SwiftPMDirectHarness<BoundedExecutor>>.breaksEven(
            covered: 7,
            workers: 1,
            suiteNanoseconds: 0,
            spawnNanoseconds: second
        )
    )
    // A start under 0.25 s: never, however many mutants.
    #expect(
        !SharedProcessHarness<SwiftPMDirectHarness<BoundedExecutor>>.breaksEven(
            covered: 500,
            workers: 1,
            suiteNanoseconds: 0,
            spawnNanoseconds: second / 5
        )
    )
    // 20 mutants × 0.4 s saved = 8 s > 4 workers × (2 × 0.5 s + 0.4 s) = 5.6 s.
    #expect(
        SharedProcessHarness<SwiftPMDirectHarness<BoundedExecutor>>.breaksEven(
            covered: 20,
            workers: 4,
            suiteNanoseconds: second / 2,
            spawnNanoseconds: 2 * second / 5
        )
    )
    // A slow suite: 20 × 0.4 s = 8 s < 4 × (2 × 3 s + 0.4 s) = 25.6 s.
    #expect(
        !SharedProcessHarness<SwiftPMDirectHarness<BoundedExecutor>>.breaksEven(
            covered: 20,
            workers: 4,
            suiteNanoseconds: 3 * second,
            spawnNanoseconds: 2 * second / 5
        )
    )
    // Nothing to save when a start costs nothing.
    #expect(
        !SharedProcessHarness<SwiftPMDirectHarness<BoundedExecutor>>.breaksEven(
            covered: 500,
            workers: 1,
            suiteNanoseconds: 0,
            spawnNanoseconds: 0
        )
    )
}
