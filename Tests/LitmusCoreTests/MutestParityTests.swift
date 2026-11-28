import Foundation
import ProjectModel
import Testing

@testable import LitmusCore

/// Sites mutest-swift mutates that Litmus missed, and mutants Litmus counted twice.
@Suite struct MutestParityTests {
    static let picker = #"""
        import SwiftUI

        struct Picker: View {
            @State var isPresented = false
            @State var message = "x"

            var body: some View {
                VStack {
                    Text(message)
                    Text("other")
                }
                .onChange(of: isPresented) {
                    isPresented = false
                    Task {
                        try? await Task.sleep(nanoseconds: 1)
                        message = ""
                    }
                }
                .sheet(isPresented: $isPresented, onDismiss: { reset(); log() }) {
                    Text("sheet")
                }
            }

            func reset() {}
            func log() {}
        }
        """#

    @Test func `calls inside action closures of a view body are removable; view content and waits are not`() throws {
        let sites = try MutationPlanner.mutations(in: Self.picker, path: "Picker.swift", operators: [.removeCall])
        #expect(
            Set(sites.map(\.original)) == [
                "Task {\n                try? await Task.sleep(nanoseconds: 1)\n                message = \"\"\n            }",
                "reset()", "log()",
            ]
        )
    }

    @Test func `a comparison's negation is not mutated twice`() throws {
        let source = """
            func f(_ x: Int, _ flag: Bool) -> Int {
                if x == 1 { return 0 }
                return x < 2 ? 1 : 2
            }
            func g(_ flag: Bool) -> Int { flag ? 1 : 2 }
            """
        let sites = try MutationPlanner.mutations(
            in: source,
            path: "F.swift",
            operators: [.replaceRelational, .swapTernary, .negateCondition]
        )
        #expect(!sites.contains { $0.operatorID == .swapTernary && $0.original == "x < 2" })
        #expect(!sites.contains { $0.operatorID == .negateCondition && $0.original == "x == 1" })
        #expect(sites.contains { $0.operatorID == .replaceRelational && $0.replacement == "x >= 2" })
        #expect(sites.contains { $0.operatorID == .swapTernary && $0.original == "flag" })
    }

    @Test func `two operators making the same edit are one mutant`() throws {
        let sites = try MutationPlanner.mutations(
            in: "func name(_ s: String?) -> String { s ?? \"\" }\n",
            path: "N.swift",
            operators: [.returnBoundary, .replaceNilCoalescing]
        )
        #expect(sites.filter { $0.replacement == "\"\"" }.count == 1)
    }

    @Test func `a changed comment inside a multi-line mutant reaches no site; a changed code line does`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("litmus-comment-\(UUID().uuidString)")
            .path
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/Sources/A", withIntermediateDirectories: true)
        try Data(
            "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"A\", targets: [.target(name: \"A\")])\n"
                .utf8
        )
        .write(to: URL(fileURLWithPath: root + "/Package.swift"))
        let source = """
            func run(_ work: () -> Void) {}
            func f() {
                run {
                    // a comment the change edits
                    print("x")
                    g()
                }
            }
            func g() {}
            """
        try Data(source.utf8).write(to: URL(fileURLWithPath: root + "/Sources/A/A.swift"))
        func plan(_ line: Int) async throws -> [Mutation] {
            let scope = ChangeScope(
                changed: ChangedLines(files: ["Sources/A/A.swift": [line...line]]),
                breadth: .lines,
                source: "test",
                digest: "d"
            )
            return try await MutationPlanner.plan(
                root: root,
                scope: scope,
                operators: [.removeCall, .emptyClosureBody]
            )
            .mutations
        }
        #expect(try await plan(4).isEmpty)
        #expect(try await plan(6).contains { $0.original == "g()" })
    }

    #if os(macOS)
        @Test func `narrowing edits the copy's scheme and plan down to the covering test targets`() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "litmus-narrow-\(UUID().uuidString)"
            ).path
            defer { try? FileManager.default.removeItem(atPath: root) }
            let schemes = root + "/App.xcodeproj/xcshareddata/xcschemes"
            try FileManager.default.createDirectory(atPath: schemes, withIntermediateDirectories: true)
            func reference(_ name: String) -> String {
                #"<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="\#(name)" BuildableName="\#(name)" BlueprintName="\#(name)" ReferencedContainer="container:App.xcodeproj"></BuildableReference>"#
            }
            let scheme = """
                <?xml version="1.0" encoding="UTF-8"?>
                <Scheme version="1.7">
                <BuildAction buildImplicitDependencies="YES"><BuildActionEntries>
                <BuildActionEntry buildForTesting="YES" buildForRunning="YES">\(reference("App"))</BuildActionEntry>
                <BuildActionEntry buildForTesting="YES" buildForRunning="NO">\(reference("AppTests"))</BuildActionEntry>
                </BuildActionEntries></BuildAction>
                <TestAction><TestPlans>
                <TestPlanReference reference="container:App.xctestplan" default="YES"></TestPlanReference>
                <TestPlanReference reference="container:Other.xctestplan"></TestPlanReference>
                </TestPlans></TestAction>
                </Scheme>
                """
            try Data(scheme.utf8).write(to: URL(fileURLWithPath: schemes + "/App.xcscheme"))
            let plan: [String: Any] = [
                "version": 1,
                "testTargets": ["AppTests", "FeatureTests", "OtherTests"].map {
                    ["target": ["name": $0, "identifier": $0, "containerPath": "container:App.xcodeproj"]]
                },
            ]
            try JSONSerialization.data(withJSONObject: plan).write(to: URL(fileURLWithPath: root + "/App.xctestplan"))
            let result = XcodeBuildNarrowing.narrow(
                workspace: root,
                container: "App.xcodeproj",
                scheme: "App",
                testPlan: nil,
                keep: ["FeatureTests", "MissingTests"]
            )
            #expect(try result.get() == ["FeatureTests"])
            let edited = try String(contentsOfFile: schemes + "/App.xcscheme", encoding: .utf8)
            #expect(!edited.contains("Other.xctestplan"))
            #expect(!edited.contains(#"buildForTesting="YES""#))
            let narrowed = try JSONSerialization.jsonObject(
                with: Data(contentsOf: URL(fileURLWithPath: root + "/App.xctestplan"))
            )
            let names = ((narrowed as? [String: Any])?["testTargets"] as? [[String: Any]])?
                .compactMap { ($0["target"] as? [String: Any])?["name"] as? String }
            #expect(names == ["FeatureTests"])
            let none = XcodeBuildNarrowing.narrow(
                workspace: root,
                container: "App.xcodeproj",
                scheme: "App",
                testPlan: nil,
                keep: ["Absent"]
            )
            #expect((try? none.get()) == nil)
        }
    #endif
}
