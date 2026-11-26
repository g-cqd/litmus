import Foundation
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
}
