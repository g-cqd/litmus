import Foundation
import Testing

@testable import LitmusCore

@Suite struct PhaseFTests {
    @Test func `SwiftUI UI operators mutate disabled predicates, presentations, and lifecycle actions`() throws {
        let source = #"""
            import SwiftUI

            struct Item: Identifiable { let id: Int }

            struct CheckoutView: View {
                @State private var showSheet = false
                @State private var selectedItem: Item? = nil
                var canSubmit = false

                var body: some View {
                    NavigationStack {
                        VStack {
                            Text("Checkout")
                            Button("Pay") { submit() }
                                .disabled(!canSubmit)
                        }
                        .onAppear { load() }
                        .task { await refresh() }
                        .sheet(isPresented: $showSheet) {
                            Text("Receipt")
                        }
                        .popover(item: $selectedItem) { item in
                            Text("\(item.id)")
                        }
                        .navigationDestination(for: Int.self) { route in
                            Text("Route \(route)")
                        }
                    }
                }

                func submit() {}
                func load() {}
                func refresh() async {}
            }
            """#
        let sites = try MutationPlanner.mutations(
            in: source,
            path: "CheckoutView.swift",
            operators: MutationOperator.uiOperators
        )
        #expect(try MutationOperator.parse("ui") == MutationOperator.uiOperators)
        #expect(sites.allSatisfy { $0.operatorID.domain == .ui })
        #expect(
            sites.contains {
                $0.operatorID == .negateDisabled && $0.original == "!canSubmit" && $0.replacement == "canSubmit"
            }
        )
        #expect(
            sites.contains {
                $0.operatorID == .removePresentation && $0.original == "$showSheet"
                    && $0.replacement == ".constant(false)"
            }
        )
        #expect(
            sites.contains {
                $0.operatorID == .removePresentation && $0.original == "$selectedItem"
                    && $0.replacement == ".constant(nil)"
            }
        )
        #expect(sites.contains { $0.operatorID == .removePresentation && $0.original.contains("Route") })
        #expect(sites.filter { $0.operatorID == .removeViewAction }.count == 2)
    }

    @Test func `xctestrun patching injects UITargetAppEnvironmentVariables on UI test bundles for zero-setup XCUITest`()
        throws
    {
        let raw: [String: Any] = [
            "TestConfigurations": [
                [
                    "TestTargets": [
                        [
                            "BlueprintName": "AppTests",
                            "TestBundlePath": "__TESTROOT__/AppTests.xctest",
                            "IsUITestBundle": false,
                        ],
                        [
                            "BlueprintName": "AppUITests",
                            "TestBundlePath": "__TESTROOT__/AppUITests-Runner.app/PlugIns/AppUITests.xctest",
                            "UITargetAppPath": "__TESTROOT__/App.app",
                            "IsUITestBundle": true,
                        ],
                    ]
                ]
            ]
        ]
        let injected = [
            "LITMUS_ACTIVE_ID_abcd1234": "0123456789abcdef",
            "LITMUS_COVERAGE_DIR_abcd1234": "/tmp/cov",
            "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
        ]
        let (patchedAny, count) = try XcodeHarness<BoundedExecutor>.patchTestRunPlist(
            raw,
            injected: injected,
            products: "/build/Products"
        )
        #expect(count == 2)
        let patched = try #require(patchedAny as? [String: Any])
        let configs = try #require(patched["TestConfigurations"] as? [[String: Any]])
        let targets = try #require(configs.first?["TestTargets"] as? [[String: Any]])
        let unit = try #require(targets.first { ($0["BlueprintName"] as? String) == "AppTests" })
        let ui = try #require(targets.first { ($0["BlueprintName"] as? String) == "AppUITests" })

        #expect(unit["UITargetAppEnvironmentVariables"] == nil)
        let uiTargetEnv = try #require(ui["UITargetAppEnvironmentVariables"] as? [String: String])
        #expect(uiTargetEnv["LITMUS_ACTIVE_ID_abcd1234"] == "0123456789abcdef")
        #expect(uiTargetEnv["LITMUS_COVERAGE_DIR_abcd1234"] == "/tmp/cov")
        #expect(uiTargetEnv["DEVELOPER_DIR"] == nil)
        #expect((ui["UITargetAppPath"] as? String) == "/build/Products/App.app")
    }

    #if os(macOS)
        @Test(.timeLimit(.minutes(2))) func `rendered SwiftUI UI operator schemas typecheck under Swift 6`() throws {
            let source = #"""
                import SwiftUI

                struct Item: Identifiable { let id: Int }

                struct SampleScreen: View {
                    @State private var open = false
                    @State private var item: Item? = nil
                    var ready = true

                    var body: some View {
                        NavigationStack {
                            VStack {
                                Text("Header")
                                Button("Continue") { go() }
                                    .disabled(!ready)
                            }
                            .onAppear { go() }
                            .sheet(isPresented: $open) { Text("Modal") }
                            .popover(item: $item) { it in Text("\(it.id)") }
                            .navigationDestination(for: Int.self) { n in Text("Page \(n)") }
                        }
                    }

                    func go() {}
                }
                """#
            let sites = try MutationPlanner.mutations(
                in: source,
                path: "SampleScreen.swift",
                operators: MutationOperator.uiOperators
            )
            #expect(sites.count >= 6)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("litmus-f1-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            for (idx, batch) in SchemaWriter.batches(sites).enumerated() {
                let rendered = try SchemaWriter.schema(source, mutations: batch, token: "11223344")
                let file = dir.appendingPathComponent("Screen-\(idx).swift")
                try Data(rendered.text.utf8).write(to: file)
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                proc.arguments = [
                    "--sdk", "macosx", "swiftc", "-typecheck", "-swift-version", "6", "-parse-as-library", file.path,
                ]
                let errPipe = Pipe()
                proc.standardError = errPipe
                try proc.run()
                let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                proc.waitUntilExit()
                #expect(proc.terminationStatus == 0, "SwiftUI batch \(idx) failed typecheck:\n\(err)")
            }
        }
    #endif
}
