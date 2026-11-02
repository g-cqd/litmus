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
    #expect(sites.contains { $0.original == "a && b" && $0.replacement == "a || b" })
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
