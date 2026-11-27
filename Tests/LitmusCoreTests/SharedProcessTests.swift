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
            options.sharedProcess = shared
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
    }
#endif
