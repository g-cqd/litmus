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
        // `.onAppear`, `.task`, and the `Button("Pay")` action.
        #expect(sites.filter { $0.operatorID == .removeViewAction }.count == 3)
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

    @Test func `result store inspect, garbage-collect, pack, and unpack verify integrity and reject tampering`()
        throws
    {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("litmus-f3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let storeDir = scratch.appendingPathComponent("store").path
        let store = try ResultStore(
            directory: storeDir,
            readOnly: false,
            limitMiB: 64,
            forbidden: scratch.appendingPathComponent("subject").path,
            secret: "top-secret"
        )
        let m1 = Mutation(
            id: "0011223344556677",
            path: "Sources/A/A.swift",
            line: 2,
            column: 5,
            operatorID: .replaceRelational,
            start: 10,
            end: 15,
            original: "a < b",
            replacement: "a <= b",
            sourceFingerprint: String(repeating: "a", count: 64)
        )
        let key1 = String(repeating: "1", count: 64)
        try store.put(key1, MutationResult(mutation: m1, verdict: .killed, reason: "killed"), runID: "run-1")

        let badDir = storeDir + "/v1/records/ff"
        try FileManager.default.createDirectory(atPath: badDir, withIntermediateDirectories: true)
        try Data("corrupt".utf8)
            .write(to: URL(fileURLWithPath: badDir + "/" + String(repeating: "f", count: 64) + ".rec"))

        let status = try ResultStore.inspect(directory: storeDir, secret: "top-secret")
        #expect(status.records == 1 && status.corruptRecords == 1)

        let gc = try ResultStore.garbageCollect(directory: storeDir, secret: "top-secret")
        #expect(gc.removedCorrupt == 1 && gc.remaining == 1)

        let archive = scratch.appendingPathComponent("cache.pack").path
        #expect(try ResultStore.pack(directory: storeDir, outputArchive: archive, secret: "top-secret") == 1)

        let wrongDest = scratch.appendingPathComponent("wrong").path
        #expect(throws: LitmusFailure.self) {
            _ = try ResultStore.unpack(archivePath: archive, into: wrongDest, secret: "wrong-secret")
        }

        let restoredDir = scratch.appendingPathComponent("restored").path
        let first = try ResultStore.unpack(archivePath: archive, into: restoredDir, secret: "top-secret")
        #expect(first.imported == 1 && first.skippedExisting == 0)
        let second = try ResultStore.unpack(archivePath: archive, into: restoredDir, secret: "top-secret")
        #expect(second.imported == 0 && second.skippedExisting == 1)

        let restored = try ResultStore(
            directory: restoredDir,
            readOnly: true,
            limitMiB: 64,
            forbidden: scratch.appendingPathComponent("subject").path,
            secret: "top-secret"
        )
        #expect(restored.lookup(key1, mutation: m1)?.result.verdict == .killed)
    }

    @Test func `GitHubReport escapes workflow-command characters and duration-balanced sharding balances heavy units`()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("litmus-gh-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/Sources/Fast", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/Sources/Mid", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/Sources/Slow", withIntermediateDirectories: true)
        try Data("func a(_ x: Int) -> Bool { x < 1 && x > 0 }\n".utf8)
            .write(to: URL(fileURLWithPath: root + "/Sources/Fast/A.swift"))
        try Data("func b(_ x: Int) -> Bool { x < 1 && x > 0 }\n".utf8)
            .write(to: URL(fileURLWithPath: root + "/Sources/Mid/B.swift"))
        try Data("func c(_ x: Int) -> Bool { x < 1 }\n".utf8)
            .write(to: URL(fileURLWithPath: root + "/Sources/Slow/C.swift"))

        let plan = try await MutationPlanner.plan(root: root, operators: [.replaceRelational])
        let entries = try await WorkspaceSnapshot.currentEntries(root)
        let prov = RunProvenance(
            toolVersion: LitmusVersion.current,
            snapshotSHA256: Digest.sha256(try ArtifactCodec.json(entries)),
            inputs: entries,
            driver: try BuildDriver(root: root, scheme: nil, destination: nil),
            toolchain: "test",
            startedAt: "2026-11-27T00:00:00Z",
            executionPolicy: RunArtifact.executionPolicy
        )
        var prior = RunArtifact(provenance: prov, plan: plan)
        prior.complete = true
        prior.results = plan.mutations.map { m in
            let nanos: Int64 = m.path.contains("/Slow/") ? 25_000_000_000 : 50_000_000
            return MutationResult(mutation: m, verdict: .survived, reason: "line1\nline2,50%", nanoseconds: nanos)
        }
        let (s1, r1) = Sharding.select(plan, try ShardSelection(index: 1, count: 2), prior: prior)
        let (s2, r2) = Sharding.select(plan, try ShardSelection(index: 2, count: 2), prior: prior)
        #expect(r1.units == ["Sources/Slow"])
        #expect(r2.units == ["Sources/Fast", "Sources/Mid"])
        #expect(s1.mutations.count + s2.mutations.count == plan.mutations.count)

        let report = try await MutationReport.make(prior, root: root, relative: true)
        let gh = GitHubReport.render(report, root: root, maxAnnotations: 2)
        #expect(gh.contains("::warning file=Sources/Fast/A.swift,line=1,"))
        #expect(gh.contains("%0A") && gh.contains("%25"))
        #expect(gh.contains("::notice title=Litmus::"))
    }

    #if os(macOS)
        @Test(.timeLimit(.minutes(10))) func `rendered SwiftUI UI operator schemas typecheck under Swift 6`()
            async throws
        {
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
                let typecheck = try await runTool(
                    "/usr/bin/xcrun",
                    ["--sdk", "macosx", "swiftc", "-typecheck", "-swift-version", "6", "-parse-as-library", file.path]
                )
                #expect(typecheck.status == 0, "SwiftUI batch \(idx) failed typecheck:\n\(typecheck.output)")
            }
        }
    #endif
}
