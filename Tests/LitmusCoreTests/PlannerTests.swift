import Foundation
import Testing

@testable import LitmusCore

@Test func `plans the three default operators without mutating bindings`() throws {
    let source =
        "func f(_ a: Bool, _ b: Bool, _ v: Int?) -> Bool { if let v, a && b { return v > 0 }; return a ? b : a }"
    let sites = try MutationPlanner.mutations(in: source, path: "Sources/F.swift")
    #expect(
        sites.map(\.operatorID).sorted { $0.rawValue < $1.rawValue } == [
            .negateCondition, .replaceLogical, .swapTernary,
        ]
    )
    #expect(sites.contains { $0.original == "a && b" && $0.replacement == "(a) || (b)" })
}

@Test func `discovery is deterministic and UTF8 ranges preserve Unicode`() throws {
    let source = "func f(é: Bool) -> Bool { é ? true : false }"
    let sites = try MutationPlanner.mutations(in: source, path: "Sources/É.swift")
    let site = try #require(sites.first)
    #expect(site.original == "é")
    #expect(String(decoding: Array(source.utf8)[site.start..<site.end], as: UTF8.self) == "é")
    #expect(try MutationPlanner.mutations(in: source, path: "Sources/É.swift") == sites)
}

@Test func `strings comments and conditional compilation conditions are not operators`() throws {
    let source = """
        // if a && b
        let text = "a || b"
        #if DEBUG && os(iOS)
        func f(a: Bool) -> Int { a ? 1 : 2 }
        #endif
        """
    let sites = try MutationPlanner.mutations(in: source, path: "F.swift")
    #expect(sites.count == 1)
    #expect(sites.first?.operatorID == .swapTernary)
}

@Test func `malformed source is rejected rather than partially planned`() throws {
    #expect(throws: (any Error).self) { try MutationPlanner.mutations(in: "func broken( {", path: "F.swift") }
}

@Test func `overlapping expressions are placed in different schema batches`() throws {
    let sites = try MutationPlanner.mutations(
        in: "func f(a: Bool,b: Bool,c: Bool)->Bool { a && (b || c) }",
        path: "F.swift"
    )
    let batches = SchemaWriter.batches(sites)
    #expect(batches.count == 2)
    #expect(batches.flatMap { $0 }.count == sites.count)
    for batch in batches {
        for left in batch {
            for right in batch where left.id != right.id {
                #expect(left.path != right.path || left.end <= right.start || right.end <= left.start)
            }
        }
    }
}

@Test func `schema uses immutable startup selection and refuses stale input`() throws {
    let source = "func f(a: Bool)->Int { a ? 1 : 2 }"
    let sites = try MutationPlanner.mutations(in: source, path: "F.swift")
    let rewritten = try SchemaWriter.render(source, mutations: sites)
    #expect(rewritten.contains("LITMUS_ACTIVE_ID"))
    #expect(rewritten.contains("private let"))
    #expect(rewritten.contains("!(a)"))
    #expect(throws: (any Error).self) { try SchemaWriter.render("// changed\n" + source, mutations: sites) }
}

@Test func `logical replacement keeps the folded grouping of its operands`() throws {
    let sites = try MutationPlanner.mutations(
        in: "func f(a: Bool, b: Bool, c: Bool) -> Bool { a || b || c }",
        path: "F.swift"
    )
    let outer = try #require(sites.first { $0.original == "a || b || c" })
    #expect(outer.replacement == "(a || b) && (c)")
}

@Test func `sites inside macro expansions are excluded with a reason, never dropped`() throws {
    let found = try MutationPlanner.discover(in: "func f(a: Bool, b: Bool) -> Bool { #check(a && b) }", path: "F.swift")
    #expect(found.sites.isEmpty)
    #expect(found.excluded.map(\.site.original) == ["a && b"])
    #expect(found.excluded.first?.reason.contains("macro") == true)
}

@Test func `every mutant gets an inlinable-safe once-initialised activation`() throws {
    let source = "public func f(_ a: Bool, limit: Int = (true ? 1 : 2)) -> Bool { a }"
    let sites = try MutationPlanner.mutations(in: source, path: "Sources/F.swift")
    let site = try #require(sites.first)
    let schema = try SchemaWriter.schema(source, mutations: [site])
    #expect(schema.text.contains("@usableFromInline nonisolated internal let __litmus_"))
    #expect(schema.text.contains("_\(site.id): Swift.Bool = "))
    #expect(schema.text.contains("LITMUS_COVERAGE_DIR"))
    #expect(schema.lines[site.id] == 1...1)
}

@Test func `top-level code gets its declarations before the code that reads them`() throws {
    let source = "import Foundation\nlet x = CommandLine.arguments.count > 1\nprint(x ? 1 : 2)\n"
    let sites = try MutationPlanner.mutations(in: source, path: "Sources/Tool/main.swift")
    let schema = try SchemaWriter.schema(source, mutations: sites)
    let declaration = try #require(schema.text.range(of: "nonisolated internal let"))
    let use = try #require(schema.text.range(of: "print("))
    #expect(declaration.lowerBound < use.lowerBound)
    #expect(schema.text.components(separatedBy: "import Foundation").count == 2)
    let site = try #require(sites.first)
    #expect(schema.lines[site.id].map { $0.lowerBound > 3 } == true)
}

@Test func `mutants on the same expression share one schema build`() throws {
    let source = "func f(a: Bool, b: Bool) -> Int { if a && b { return 1 }; return 0 }"
    let sites = try MutationPlanner.mutations(in: source, path: "F.swift")
    #expect(sites.count == 2)
    #expect(SchemaWriter.batches(sites).count == 1)
    let schema = try SchemaWriter.schema(source, mutations: sites)
    #expect(schema.text.components(separatedBy: " ? (").count == 3)
    #expect(schema.text.contains(": (a && b)) { return 1 }"))
    #expect(Set(schema.lines.values) == [1...1])
}

@Test func `the census counts candidate operators by schema shape and blocks statements in builders`() throws {
    let source = """
        func f(_ a: Int, _ b: Int, name: String?) -> Bool {
            defer { close() }
            log()
            if let name, a < b { return name == "x" }
            return a + b > 0 && true
        }
        func close() {}
        func log() {}
        struct V {
            var body: some View { refresh() }
        }
        """
    let entries = try MutationCensus.count(source: source)
    #expect(entries["relational-boundary-and-negation"]?.sites == 2)
    #expect(entries["relational-boundary-and-negation"]?.mutants == 4)
    #expect(entries["relational-equality"]?.sites == 1)
    #expect(entries["arithmetic-replace"]?.sites == 1)
    #expect(entries["optional-binding-to-nil"]?.sites == 1)
    #expect(entries["defer-removal (fcheck)"]?.sites == 1)
    #expect(entries["cleanup-call-removal (fcheck)"]?.sites == 1)
    #expect(entries["void-call-removal"]?.sites == 1)
    #expect(entries["void-call-removal"]?.blocked == 1)
    #expect(entries["return-default-bool"]?.mutants == 2)
    #expect(entries["boolean-literal-flip"]?.shape == .expression)
}

@Test func `the shared configuration's litmus section is read beside the other tools' sections`() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("litmus-config-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: root) }
    try Data(#"{"exclude": ["Generated/"], "litmus": {"exclude": ["Fixtures/"]}, "arcleak": {"x": 1}}"#.utf8)
        .write(to: URL(fileURLWithPath: root + "/.swift-analyzers.json"))
    let configuration = try LitmusConfiguration.load(root: root, explicit: nil)
    #expect(Set(configuration.exclude) == ["Generated/", "Fixtures/"])
}

@Test func `an include list mutates only the files it names, and an empty match is an error`() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("litmus-include-\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: root) }
    try FileManager.default.createDirectory(atPath: root + "/Sources/Lib", withIntermediateDirectories: true)
    try Data(
        "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"Lib\", targets: [.target(name: \"Lib\")])\n"
            .utf8
    )
    .write(to: URL(fileURLWithPath: root + "/Package.swift"))
    for name in ["A", "B"] {
        try Data("func \(name.lowercased())(_ x: Bool) -> Bool { x ? true : false }\n".utf8)
            .write(to: URL(fileURLWithPath: root + "/Sources/Lib/\(name).swift"))
    }
    let all = try await MutationPlanner.plan(root: root)
    let only = try await MutationPlanner.plan(root: root, include: ["Sources/Lib/B.swift"])
    #expect(Set(all.mutations.map(\.path)) == ["Sources/Lib/A.swift", "Sources/Lib/B.swift"])
    #expect(Set(only.mutations.map(\.path)) == ["Sources/Lib/B.swift"])
    await #expect(throws: LitmusFailure.self) { try await MutationPlanner.plan(root: root, include: ["Nowhere.swift"]) }
}

/// Anchored identity: a mutant keeps its id when code moves around it, so results can be reused and runs
/// compared; it changes when its own code or its declaration's name does.
@Suite struct AnchoredIdentityTests {
    private let source = """
        struct Gate {
            var open = false
            func check(_ a: Bool, _ b: Bool) -> Bool {
                if a && b { return true }
                if a && b { return open }
                return a ? b : false
            }
        }
        """
    @Test func `ids survive lines added above and edits in other declarations`() throws {
        let before = try MutationPlanner.mutations(in: source, path: "Sources/Gate.swift")
        let moved = "// a\n// b\n// c\n" + source.replacingOccurrences(of: "var open = false", with: "var open = true")
        let after = try MutationPlanner.mutations(in: moved, path: "Sources/Gate.swift")
        #expect(before.map(\.id) == after.map(\.id))
        #expect(before.map(\.line) != after.map(\.line))
        #expect(Set(before.map(\.id)).count == before.count)
        #expect(before.allSatisfy { $0.declaration == "Gate.check(_:_:)" })
        // The declaration's text is unchanged: same digest, so `--reuse declaration` may reuse.
        #expect(before.map(\.declarationDigest) == after.map(\.declarationDigest))
    }

    @Test func `identical sites in one declaration are told apart by their order`() throws {
        let sites = try MutationPlanner.mutations(in: source, path: "Sources/Gate.swift")
        let logical = sites.filter { $0.operatorID == .replaceLogical }
        #expect(logical.count == 2)
        #expect(logical[0].id != logical[1].id)
    }

    @Test func `ids change with the site's code, the declaration's name or the path`() throws {
        let before = try MutationPlanner.mutations(in: source, path: "Sources/Gate.swift")
        let renamed = try MutationPlanner.mutations(
            in: source.replacingOccurrences(of: "func check(", with: "func verify("),
            path: "Sources/Gate.swift"
        )
        #expect(Set(before.map(\.id)).isDisjoint(with: renamed.map(\.id)))
        let elsewhere = try MutationPlanner.mutations(in: source, path: "Sources/Other.swift")
        #expect(Set(before.map(\.id)).isDisjoint(with: elsewhere.map(\.id)))
        let edited = try MutationPlanner.mutations(
            in: source.replacingOccurrences(of: "return a ? b : false", with: "return b ? a : false"),
            path: "Sources/Gate.swift"
        )
        let ternary = { (sites: [Mutation]) in sites.first { $0.operatorID == .swapTernary }?.id }
        #expect(ternary(before) != ternary(edited))
        // The two `a && b` sites keep their ids, but the declaration's text changed.
        let logical = { (sites: [Mutation]) in sites.filter { $0.operatorID == .replaceLogical } }
        #expect(logical(before).map(\.id) == logical(edited).map(\.id))
        #expect(logical(before).map(\.declarationDigest) != logical(edited).map(\.declarationDigest))
    }

    @Test func `declarations are named with their labels, accessors and extensions`() throws {
        let text = """
            extension Array where Element == Int {
                init(flag: Bool) { self = flag ? [1] : [] }
                var any: Bool { get { isEmpty ? false : true } }
                subscript(safe index: Int) -> Int? { indices.contains(index) ? self[index] : nil }
            }
            let top = CommandLine.arguments.isEmpty ? 0 : 1
            """
        let names = try MutationPlanner.mutations(in: text, path: "A.swift").map { $0.declaration ?? "?" }
        #expect(names == ["Array.init(flag:)", "Array.any.get", "Array.subscript(safe:)", "top"])
    }
}
