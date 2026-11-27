import Foundation
import Testing

@testable import LitmusCore

@Suite struct SwiftUIOperatorTests {
    static let screen = #"""
        import SwiftUI

        struct PayScreen: View {
            var ready = true

            var body: some View {
                VStack {
                    Button("Pay") { pay() }
                    Button(action: { pay() }) { Text("Pay again") }
                    Button { pay() } label: { Text("Labelled") }
                    Text("Total")
                        .opacity(0.5)
                        .allowsHitTesting(ready)
                        .onTapGesture { pay() }
                        .accessibilityLabel("Total amount")
                        .accessibilityHint("")
                        .accessibilityHidden(false)
                }
            }

            func pay() {}
        }
        """#

    static func sites(_ operators: Set<MutationOperator>) throws -> [Mutation] {
        try MutationPlanner.mutations(in: screen, path: "PayScreen.swift", operators: operators)
    }

    @Test func `Button actions and tap gestures are emptied, never a Button's label`() throws {
        let actions = try Self.sites([.removeViewAction]).map(\.original)
        #expect(actions.count == 4)
        #expect(actions.allSatisfy { $0 == "pay()" })
        let intent = """
            import SwiftUI
            struct S: View {
                var body: some View { Button(intent: Refresh()) { Text("Go") } }
            }
            """
        #expect(try MutationPlanner.mutations(in: intent, path: "S.swift", operators: [.removeViewAction]).isEmpty)
    }

    @Test func `view modifier arguments change without changing the view's type`() throws {
        let sites = try Self.sites([.neutralizeViewModifier])
        #expect(Set(sites.map { "\($0.original)→\($0.replacement)" }) == ["0.5→0", "ready→!(ready)"])
        #expect(MutationOperator.uiOperators.contains(.neutralizeViewModifier))
    }

    @Test func `accessibility metadata is opt-in and blanks only non-empty literals`() throws {
        let sites = try Self.sites([.removeAccessibilityMetadata])
        #expect(
            Set(sites.map { "\($0.original)→\($0.replacement)" })
                == [#""Total amount"→"""#, "false→!(false)"]
        )
        #expect(!MutationOperator.uiOperators.contains(.removeAccessibilityMetadata))
        #expect(MutationOperator.removeAccessibilityMetadata.domain == .ui)
    }

    #if os(macOS)
        @Test(.timeLimit(.minutes(10))) func `every SwiftUI operator's schema typechecks under Swift 6`() async throws {
            let operators = MutationOperator.uiOperators.union([.removeAccessibilityMetadata])
            let sites = try Self.sites(operators)
            #expect(sites.count >= 10)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("litmus-f1b-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            for (index, batch) in SchemaWriter.batches(sites).enumerated() {
                let rendered = try SchemaWriter.schema(Self.screen, mutations: batch, token: "55667788")
                let file = dir.appendingPathComponent("PayScreen-\(index).swift")
                try Data(rendered.text.utf8).write(to: file)
                let typecheck = try await runTool(
                    "/usr/bin/xcrun",
                    ["--sdk", "macosx", "swiftc", "-typecheck", "-swift-version", "6", "-parse-as-library", file.path]
                )
                #expect(typecheck.status == 0, "batch \(index) failed typecheck:\n\(typecheck.output)")
            }
        }
    #endif
}
