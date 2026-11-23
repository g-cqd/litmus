import Foundation
import Testing

@testable import LitmusCore

private let everything = MutationOperator.operators(upTo: .experimental)

private func sites(_ source: String, _ operators: Set<MutationOperator> = everything) throws -> [Mutation] {
    try MutationPlanner.mutations(in: source, path: "Sources/F.swift", operators: operators)
}

@Test func `the default operator set is the stable tier and adds nothing else`() throws {
    #expect(MutationOperator.defaults == [.negateCondition, .swapTernary, .replaceLogical])
    let source = "func f(_ a: Int, _ b: Int) -> Bool { let t = true; log(); return a < b + 1 && t }"
    let found = try MutationPlanner.mutations(in: source, path: "F.swift")
    #expect(found.allSatisfy { MutationOperator.defaults.contains($0.operatorID) })
    #expect(found.count == 1)
}

@Test func `tiers are cumulative and parse from rule identifiers`() throws {
    #expect(MutationOperator.operators(upTo: .standard).contains(.replaceRelational))
    #expect(!MutationOperator.operators(upTo: .standard).contains(.removeCall))
    #expect(MutationOperator.operators(upTo: .experimental) == Set(MutationOperator.allCases))
    #expect(try MutationOperator.parse("flip-boolean, remove-call") == [.flipBoolean, .removeCall])
    #expect(throws: LitmusFailure.self) { try MutationOperator.parse("nope") }
    #expect(throws: LitmusFailure.self) { try MutationOperator.parse(" , ") }
}

@Test func `relational operators shift boundaries and negate, keeping the text around the operator`() throws {
    let found = try sites("func f(_ a: Int, _ b: Int) -> Bool { /* c */ a < b }", [.replaceRelational])
    #expect(found.map(\.replacement).sorted() == ["a <= b", "a >= b"])
    #expect(found.allSatisfy { $0.original == "a < b" })
    let equality = try sites("func f(_ a: Int?) -> Bool { a == nil }", [.replaceRelational])
    #expect(equality.map(\.replacement) == ["a != nil"])
    #expect(try sites("func f(_ a: AnyObject, _ b: AnyObject) -> Bool { a === b }", [.replaceRelational]).isEmpty)
    let spaced = try sites("func f(_ a: Int, _ b: Int) -> Bool { a  >=  b }", [.replaceRelational])
    #expect(spaced.map(\.replacement).sorted() == ["a  <  b", "a  >  b"])
}

@Test func `arithmetic exchanges operators and leaves string concatenation alone`() throws {
    let found = try sites("func f(_ a: Int, _ b: Int) -> Int { a % b + a * b }", [.replaceArithmetic])
    #expect(found.count == 3)
    #expect(found.contains { $0.original == "a % b" && $0.replacement == "a * b" })
    #expect(found.contains { $0.original == "a * b" && $0.replacement == "a / b" })
    #expect(found.contains { $0.original == "a % b + a * b" && $0.replacement == "a % b - a * b" })
    #expect(try sites("func f(_ a: String) -> String { \"x\" + a }", [.replaceArithmetic]).isEmpty)
}

@Test func `boolean literals flip except in case patterns and attributes`() throws {
    let source = """
        @Attr(true) struct S {
            var x = true
            func f(_ v: Bool) -> Int {
                switch v { case true: return 1; case false: return 0 }
            }
        }
        """
    let found = try sites(source, [.flipBoolean])
    #expect(found.map(\.original) == ["true"])
    #expect(found.first?.replacement == "false")
}

@Test func `call removal skips logging, implicit returns, builders and initializer chaining`() throws {
    let source = """
        final class C: Base {
            init() { super.init(); setup(); self.configure() }
            func a() { print("x"); logger.info("y"); try await work(); precondition(true) }
            func b() -> Int { compute() }
            func c() { only() }
            var d: Int { value() }
            var e: Int { get { value() } set { store(newValue) } }
            func g() { let h = { run() }; h() }
            @ViewBuilder var body: some View { Text("t"); helper() }
        }
        """
    let found = try sites(source, [.removeCall]).map(\.original).sorted()
    #expect(found == ["h()", "only()", "self.configure()", "setup()", "store(newValue)", "try await work()"])
}

@Test func `a removed call is skipped, not replaced, in its schema`() throws {
    let source = "func f() { setup(); run() }\n"
    let found = try sites(source, [.removeCall])
    #expect(found.count == 2)
    let batch = SchemaWriter.batches(found).flatMap { $0 }
    let schema = try SchemaWriter.schema(source, mutations: batch)
    #expect(schema.text.contains("{ if !__litmus_"))
    #expect(!schema.text.contains("? ()"))
    for site in found { #expect(schema.text.contains("_\(site.id) { \(site.original) }")) }
}

@Test func `suppression directives name the new rules`() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("litmus-ops-\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: root) }
    try FileManager.default.createDirectory(atPath: root + "/Sources/Lib", withIntermediateDirectories: true)
    try Data(
        "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"Lib\", targets: [.target(name: \"Lib\")])\n"
            .utf8
    )
    .write(to: URL(fileURLWithPath: root + "/Package.swift"))
    let source = """
        func f(_ a: Int, _ b: Int) -> Bool {
            // @lm:accept:next replace-relational -- boundary is intentional
            return a < b
        }
        func g(_ a: Int, _ b: Int) -> Bool { a < b }
        """
    try Data(source.utf8).write(to: URL(fileURLWithPath: root + "/Sources/Lib/L.swift"))
    let plan = try await MutationPlanner.plan(root: root, operators: [.replaceRelational])
    #expect(plan.notes.isEmpty)
    #expect(plan.suppressed.count == 2)
    #expect(plan.mutations.count == 2)
    #expect(Set(plan.suppressed.map(\.line)) == [3])
}
