import Foundation
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
