import Foundation
import ProjectModel
import SourceCorpus
import Testing

@testable import LitmusCore

@Suite("Phase D: shared execution, inner loop, diff intelligence & operations")
struct PhaseDTests {
    // MARK: - D5.1 Tokenized schema environment

    @Test func `the environment token is eight stable hex digits that differ per subject root`() {
        let first = ActivationEnvironment.token(for: "/tmp/subject-a")
        #expect(first.count == 8)
        #expect(first.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(first == ActivationEnvironment.token(for: "/tmp/subject-a"))
        #expect(first != ActivationEnvironment.token(for: "/tmp/subject-b"))
    }

    @Test func `a tokenized schema reads only its own run's variables`() throws {
        let source = "func f(a: Bool) -> Int { a ? 1 : 2 }"
        let sites = try MutationPlanner.mutations(in: source, path: "F.swift")
        let schema = try SchemaWriter.schema(source, mutations: sites, token: "0a1b2c3d")
        for base in [
            ActivationEnvironment.activeID, ActivationEnvironment.coverageDirectory,
            ActivationEnvironment.testTracePath,
        ] {
            #expect(schema.text.contains("\"\(base)_0a1b2c3d\""))
            #expect(!schema.text.contains("\"\(base)\""))
        }
        // Without a token, the bare names stay: a schema written by an older run reads what it always read.
        let bare = try SchemaWriter.schema(source, mutations: sites)
        #expect(bare.text.contains("\"\(ActivationEnvironment.activeID)\""))
    }

    @Test func `the subject environment carries the request's tokenized keys and no bare ones`() {
        var request = TestRunRequest(
            name: "t",
            activeID: "0123456789abcdef",
            coverageDirectory: "/tmp/c",
            temporaryDirectory: "/tmp/t",
            deadline: 10,
            failFast: false
        )
        request.environmentToken = "deadbeef"
        let environment = subjectEnvironment(request)
        #expect(environment["LITMUS_ACTIVE_ID_deadbeef"] == "0123456789abcdef")
        #expect(environment["LITMUS_COVERAGE_DIR_deadbeef"] == "/tmp/c")
        #expect(environment["LITMUS_ACTIVE_ID"] == nil)
        #expect(environment["LITMUS_COVERAGE_DIR"] == nil)
        #expect(
            ActivationEnvironment.key(ActivationEnvironment.testTracePath, token: "deadbeef")
                == "LITMUS_TEST_TRACE_deadbeef"
        )
    }

    // MARK: - D2.1 --only-id

    private func sites() throws -> [Mutation] {
        let source = """
            struct Policy {
                func remaining(_ available: Int, _ reserved: Int) -> Int {
                    available > reserved ? available - reserved : 0
                }
            }
            """
        return try MutationPlanner.mutations(
            in: source,
            path: "Modules/Inventory/Sources/Inventory/InventoryPolicy.swift",
            operators: Set(MutationOperator.allCases)
        )
    }

    @Test func `an id selector matches the full id or an unambiguous prefix of at least eight digits`() throws {
        let all = try sites()
        let target = try #require(all.first)
        #expect(try MutationSelector.select(all, by: [MutationSelector(parsing: target.id)]).map(\.id) == [target.id])
        let prefix = String(target.id.prefix(8))
        let unique = all.filter { $0.id.hasPrefix(prefix) }.count == 1
        if unique {
            #expect(try MutationSelector.select(all, by: [MutationSelector(parsing: prefix)]).map(\.id) == [target.id])
        }
        #expect(throws: LitmusFailure.self) { try MutationSelector(parsing: "abc123") }
        #expect(throws: LitmusFailure.self) {
            try MutationSelector.select(all, by: [MutationSelector(parsing: String(repeating: "0", count: 16))])
        }
    }

    @Test func `a location selector matches by path suffix, line and optional operator`() throws {
        let all = try sites()
        let onLine = all.filter { ($0.line...$0.endLine).contains(3) }
        let byLine = try MutationSelector.select(all, by: [MutationSelector(parsing: "InventoryPolicy.swift:3")])
        #expect(Set(byLine.map(\.id)) == Set(onLine.map(\.id)))
        #expect(!byLine.isEmpty)
        let relational = try MutationSelector.select(
            all,
            by: [MutationSelector(parsing: "Inventory/InventoryPolicy.swift:3:replace-relational")]
        )
        #expect(!relational.isEmpty)
        #expect(relational.allSatisfy { $0.operatorID == .replaceRelational })
        // A path must match whole components: "Policy.swift" is not "InventoryPolicy.swift".
        #expect(throws: LitmusFailure.self) {
            try MutationSelector.select(all, by: [MutationSelector(parsing: "Policy.swift:3")])
        }
        #expect(throws: LitmusFailure.self) { try MutationSelector(parsing: "InventoryPolicy.swift:3:not-an-operator") }
        #expect(throws: LitmusFailure.self) { try MutationSelector(parsing: "InventoryPolicy.swift:0") }
    }

    @Test func `several selectors keep plan order and drop repeats`() throws {
        let all = try sites()
        guard all.count >= 2 else { return }
        let picked = try MutationSelector.select(
            all,
            by: [
                MutationSelector(parsing: all[1].id), MutationSelector(parsing: all[0].id),
                MutationSelector(parsing: all[0].id),
            ]
        )
        #expect(picked.map(\.id) == [all[0].id, all[1].id])
    }

    // MARK: - D5.4 Covering test targets in reuse keys

    /// A package with libraries A and B, each tested by its own target; the key of a mutant of A under `entries`.
    private func reuseKey(
        _ entries: [SnapshotEntry],
        selectTestTargets: Bool = true,
        root: String
    ) throws -> String {
        let source = "public func a(_ x: Bool) -> Int { x ? 1 : 2 }\n"
        let mutations = try MutationPlanner.mutations(in: source, path: "Sources/A/A.swift")
        let context = try ReuseContext(
            mode: .closure,
            root: root,
            entries: entries,
            wholeSnapshot: "whole",
            mutations: mutations,
            closureKnown: true,
            context: ReuseContextInputs(
                toolVersion: "v",
                executionPolicy: "p",
                toolchain: "t",
                driver: try BuildDriver(root: root, scheme: nil, destination: nil),
                harness: "h",
                failFast: true,
                killConfirmation: "k",
                memoryLimitMiB: 1,
                timeoutCap: 1,
                timeoutFactor: 1,
                minimumTimeout: 1,
                baselineRepetitions: 1,
                suiteWidth: nil,
                selectTestTargets: selectTestTargets,
                background: false,
                excluded: []
            )
        )
        return context.key(try #require(mutations.first))
    }

    @Test func `a test edit invalidates the verdicts of the code it tests, not of its siblings`() throws {
        let root = SourcePath.canonical(
            FileManager.default.temporaryDirectory.appendingPathComponent("litmus-d54-\(UUID().uuidString)").path
        )
        defer { try? FileManager.default.removeItem(atPath: root) }
        let files = [
            "Package.swift": """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(
                name: "P",
                targets: [
                    .target(name: "A"), .target(name: "B"),
                    .testTarget(name: "ATests", dependencies: ["A"]),
                    .testTarget(name: "BTests", dependencies: ["B"]),
                ]
            )
            """,
            "Sources/A/A.swift": "public func a(_ x: Bool) -> Int { x ? 1 : 2 }\n",
            "Sources/B/B.swift": "public func b() {}\n",
            "Tests/ATests/ATests.swift": "import Testing\n",
            "Tests/BTests/BTests.swift": "import Testing\n",
        ]
        for (path, text) in files {
            let url = URL(fileURLWithPath: root + "/" + path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(text.utf8).write(to: url)
        }
        func entries(aTests: String = "1", bTests: String = "1", b: String = "1") -> [SnapshotEntry] {
            [
                SnapshotEntry(path: "Package.swift", sha256: "1"),
                SnapshotEntry(path: "Sources/A/A.swift", sha256: "1"),
                SnapshotEntry(path: "Sources/B/B.swift", sha256: b),
                SnapshotEntry(path: "Tests/ATests/ATests.swift", sha256: aTests),
                SnapshotEntry(path: "Tests/BTests/BTests.swift", sha256: bTests),
            ]
        }
        let base = try reuseKey(entries(), root: root)
        // The covering tests changed: the verdict may have.
        #expect(try reuseKey(entries(aTests: "2"), root: root) != base)
        // A sibling's tests changed: they never run for this mutant.
        #expect(try reuseKey(entries(bTests: "2"), root: root) == base)
        // Production code of the package still counts, conservatively.
        #expect(try reuseKey(entries(b: "2"), root: root) != base)
        // When every module runs for every mutant, every test file counts.
        let all = try reuseKey(entries(), selectTestTargets: false, root: root)
        #expect(try reuseKey(entries(bTests: "2"), selectTestTargets: false, root: root) != all)
    }

    // MARK: - D1.1 Per-test reach by default

    @Test func `per-test reach is on by default and an XCTest-only kill is never lost to narrowing`() async throws {
        #expect(RunOptions().perTestReach)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("litmus-d11-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let pkg = root.appendingPathComponent("Pkg")
        let files = [
            "Package.swift": """
            // swift-tools-version: 6.2
            import PackageDescription
            let package = Package(
                name: "Pkg",
                platforms: [.macOS(.v15)],
                targets: [.target(name: "Pkg"), .testTarget(name: "PkgTests", dependencies: ["Pkg"])]
            )
            """,
            "Sources/Pkg/Limit.swift": "public func over(_ x: Int) -> Bool { x > 5 }\n",
            // Swift Testing reaches the mutant without telling > from >=; only the XCTest boundary case does.
            "Tests/PkgTests/ReachTests.swift": """
            import Testing
            import Pkg
            @Test func farAbove() { #expect(over(10)) }
            """,
            "Tests/PkgTests/BoundaryTests.swift": """
            import XCTest
            import Pkg
            final class BoundaryTests: XCTestCase {
                func testBoundary() { XCTAssertFalse(over(5)) }
            }
            """,
        ]
        for (path, text) in files {
            let url = pkg.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(text.utf8).write(to: url)
        }
        var options = RunOptions()
        options.operators = [.replaceRelational]
        options.baselineRepetitions = 1
        options.jobs = 2
        let artifact = try await MutationRunner(executor: BoundedExecutor()).run(
            driver: try BuildDriver(root: pkg.path, scheme: nil, destination: nil),
            outputDirectory: root.appendingPathComponent("run").path,
            options: options
        )
        #expect(artifact.isSuccessfulExecution)
        let boundary = try #require(artifact.results.first { $0.mutation.replacement == "x >= 5" })
        #expect(artifact.perTestReach?[boundary.mutation.id]?.contains { $0.contains("farAbove") } == true)
        #expect(boundary.verdict == .killed)
    }

    // MARK: - D3 Test-change diff intelligence

    /// A package with libraries A and B and their test targets; returns the canonical root.
    private func twoTargetPackage() throws -> String {
        let root = SourcePath.canonical(
            FileManager.default.temporaryDirectory.appendingPathComponent("litmus-d3-\(UUID().uuidString)").path
        )
        let files = [
            "Package.swift": """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(
                name: "P",
                targets: [
                    .target(name: "A"), .target(name: "B"),
                    .testTarget(name: "ATests", dependencies: ["A"]),
                    .testTarget(name: "BTests", dependencies: ["B"]),
                ]
            )
            """,
            "Sources/A/A.swift": "public func a(_ x: Bool) -> Int { x ? 1 : 2 }\n",
            "Sources/B/B.swift": "public func b(_ y: Bool) -> Int { y ? 3 : 4 }\n",
            "Tests/ATests/ATests.swift": """
            import Testing
            import A
            struct ATests {
                @Test func first() {
                    #expect(a(true) == 1)
                }
                @Test func second() {
                    #expect(a(false) == 2)
                }
            }
            // a trailing comment
            """,
            "Tests/BTests/BTests.swift": "import Testing\nimport B\n@Test func onlyB() { #expect(b(true) == 3) }\n",
        ]
        for (path, text) in files {
            let url = URL(fileURLWithPath: root + "/" + path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(text.utf8).write(to: url)
        }
        return root
    }

    private func scope(_ files: [String: [ClosedRange<Int>]], deleted: Set<String> = []) -> ChangeScope {
        ChangeScope(changed: ChangedLines(files: files, deleted: deleted), breadth: .lines, source: "test", digest: "d")
    }

    @Test func `a test-only change plans nothing without the flag, and its target's code with it`() async throws {
        let root = try twoTargetPackage()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let change = scope(["Tests/ATests/ATests.swift": [5...5]])
        let plain = try await MutationPlanner.plan(root: root, scope: change)
        #expect(plain.mutations.isEmpty)
        let widened = change.includingTestChanges(root: root, reach: nil)
        #expect(widened.testDriven?.wholeFiles == ["Sources/A/A.swift"])
        let plan = try await MutationPlanner.plan(root: root, scope: widened)
        #expect(!plan.mutations.isEmpty)
        #expect(plan.mutations.allSatisfy { $0.path == "Sources/A/A.swift" })
        #expect(plan.scope?.testDriven?.testFiles == ["Tests/ATests/ATests.swift"])
        // A deleted test file widens to what its target covers too.
        let deletion = scope([:], deleted: ["Tests/BTests/BTests.swift"]).includingTestChanges(root: root, reach: nil)
        #expect(deletion.testDriven?.wholeFiles == ["Sources/B/B.swift"])
    }

    @Test func `with per-test reach, an edit inside one test plans only the mutants that test reached`() async throws {
        let root = try twoTargetPackage()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let sites = try MutationPlanner.mutations(
            in: "public func a(_ x: Bool) -> Int { x ? 1 : 2 }\n",
            path: "Sources/A/A.swift",
            operators: Set(MutationOperator.allCases)
        )
        let reached = try #require(sites.first)
        let other = try #require(sites.last)
        #expect(reached.id != other.id)
        var artifact = RunArtifact(
            provenance: RunProvenance(
                toolVersion: "t",
                snapshotSHA256: "s",
                inputs: [],
                driver: try BuildDriver(root: root, scheme: nil, destination: nil),
                toolchain: "t",
                startedAt: "now",
                executionPolicy: "p"
            ),
            plan: MutationPlan(root: root, analyzedFiles: 1, mutations: sites)
        )
        artifact.perTestReach = [reached.id: ["ATests.ATests/first()"], other.id: ["ATests.ATests/second()"]]

        let inFirst = scope(["Tests/ATests/ATests.swift": [5...5]]).includingTestChanges(root: root, reach: artifact)
        #expect(inFirst.testDriven?.mutants == [reached.id])
        #expect(inFirst.testDriven?.wholeFiles == [])
        #expect(inFirst.testDriven?.reachedTests == ["ATests.ATests/first()"])
        let plan = try await MutationPlanner.plan(
            root: root,
            scope: inFirst,
            operators: Set(MutationOperator.allCases)
        )
        #expect(plan.mutations.map(\.id) == [reached.id])

        // A line outside every test (the comment) cannot be resolved by reach: the target's files come in whole.
        let outside = scope(["Tests/ATests/ATests.swift": [11...11]]).includingTestChanges(root: root, reach: artifact)
        #expect(outside.testDriven?.wholeFiles == ["Sources/A/A.swift"])
        #expect(outside.testDriven?.mutants == [])

        // A test the nightly never ran (new since, or without reach) reached nothing it knows: widened, not narrowed
        // to nothing.
        artifact.perTestReach = [reached.id: ["ATests.ATests/first()"]]
        let unknown = scope(["Tests/ATests/ATests.swift": [8...8]]).includingTestChanges(root: root, reach: artifact)
        #expect(unknown.testDriven?.wholeFiles == ["Sources/A/A.swift"])
        #expect(unknown.testDriven?.mutants == [])
    }

    // MARK: - D4 Scheme synthesis

    @Test func `a workspace's synthesized scheme tests the projects it lists, not the ones beside it`() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ExampleApp").path
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("litmus-d4ws-\(UUID().uuidString)")
            .path
        defer { try? FileManager.default.removeItem(atPath: parent) }
        let workspace = parent + "/repo"
        try FileManager.default.createDirectory(
            atPath: workspace + "/Main.xcworkspace",
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(atPath: fixture, toPath: workspace + "/App")
        try FileManager.default.copyItem(atPath: fixture, toPath: workspace + "/Examples")
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <Workspace version = "1.0">
               <FileRef location = "group:App/ExampleApp.xcodeproj"></FileRef>
               <FileRef location = "container:../Outside/Outside.xcodeproj"></FileRef>
            </Workspace>
            """
        try Data(xml.utf8).write(to: URL(fileURLWithPath: workspace + "/Main.xcworkspace/contents.xcworkspacedata"))
        let scheme = try SynthesizedScheme.install(workspace: workspace, container: "Main.xcworkspace")
        #expect(scheme.targets == ["ExampleAppTests"])
        #expect(scheme.outside == [SourcePath.canonical(parent) + "/Outside/Outside.xcodeproj"])
        let text = try String(contentsOfFile: scheme.path, encoding: .utf8)
        #expect(text.contains(#"ReferencedContainer = "container:App/ExampleApp.xcodeproj""#))
        #expect(!text.contains("Examples/"))
    }

    @Test func `the synthesized scheme tests every unit-test target and lives only in the workspace copy`() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ExampleApp").path
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("litmus-d4-\(UUID().uuidString)")
            .path
        defer { try? FileManager.default.removeItem(atPath: workspace) }
        try FileManager.default.copyItem(atPath: fixture, toPath: workspace)
        try? FileManager.default.removeItem(atPath: workspace + "/ExampleApp.xcodeproj/xcshareddata")
        let (path, targets, _) = try SynthesizedScheme.install(workspace: workspace, container: "ExampleApp.xcodeproj")
        #expect(targets == ["ExampleAppTests"])
        #expect(path.hasSuffix("/ExampleApp.xcodeproj/xcshareddata/xcschemes/__LitmusAllUnitTests.xcscheme"))
        let schemes = XcodeSchemeReader.schemes(in: SourcePath.canonical(workspace + "/ExampleApp.xcodeproj"))
        #expect(schemes.map(\.name) == [SynthesizedScheme.name])
        #expect(schemes.first?.testTargets == ["ExampleAppTests"])
        // The scheme passes the same preflight a hand-written one does.
        let driver = try BuildDriver(
            root: workspace,
            container: "ExampleApp.xcodeproj",
            scheme: SynthesizedScheme.name,
            destination: "platform=iOS Simulator,name=Any"
        )
        try XcodeTestConfiguration.preflight(driver: driver, workspace: workspace)
    }

    @Test func `a test target failing unmutated is quarantined and only its mutants go unrun`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("litmus-d42-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let pkg = root.appendingPathComponent("Pkg")
        let files = [
            "Package.swift": """
            // swift-tools-version: 6.2
            import PackageDescription
            let package = Package(
                name: "Pkg",
                platforms: [.macOS(.v15)],
                targets: [
                    .target(name: "A"), .target(name: "B"),
                    .testTarget(name: "ATests", dependencies: ["A"]),
                    .testTarget(name: "BTests", dependencies: ["B"]),
                ]
            )
            """,
            "Sources/A/A.swift": "public func a(_ x: Bool) -> Int { x ? 1 : 2 }\n",
            "Sources/B/B.swift": "public func b(_ y: Bool) -> Int { y ? 3 : 4 }\n",
            "Tests/ATests/ATests.swift": "import Testing\nimport A\n@Test func both() { #expect(a(true) == 1) }\n",
            // Fails unmutated: an environment assumption that does not hold here.
            "Tests/BTests/BTests.swift": "import Testing\nimport B\n@Test func broken() { #expect(b(true) == 4) }\n",
        ]
        for (path, text) in files {
            let url = pkg.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(text.utf8).write(to: url)
        }
        var options = RunOptions()
        options.baselineRepetitions = 1
        options.jobs = 2
        let driver = try BuildDriver(root: pkg.path, scheme: nil, destination: nil)
        await #expect(throws: LitmusFailure.self) {
            try await MutationRunner(executor: BoundedExecutor()).run(
                driver: driver,
                outputDirectory: root.appendingPathComponent("strict").path,
                options: options
            )
        }
        options.skipFailingTargets = true
        let artifact = try await MutationRunner(executor: BoundedExecutor()).run(
            driver: driver,
            outputDirectory: root.appendingPathComponent("run").path,
            options: options
        )
        #expect(artifact.isSuccessfulExecution)
        let byPath = Dictionary(grouping: artifact.results, by: \.mutation.path)
        #expect(byPath["Sources/A/A.swift"]?.allSatisfy { $0.verdict == .killed } == true)
        #expect(byPath["Sources/B/B.swift"]?.allSatisfy { $0.verdict == .notRun } == true)
        #expect(artifact.budget?.stoppedBy == "failing-test-target")
        #expect(artifact.notes.contains { $0.hasPrefix("test target BTests failed unmutated") })
    }
}
