import Foundation
import Synchronization
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
    #expect(
        MutationOperator.operators(upTo: .experimental)
            == Set(MutationOperator.allCases.filter { $0.domain == .logic && $0.inDefaultTiers })
    )
    #expect(!MutationOperator.operators(upTo: .experimental).contains(.removeViewElement))
    #expect(!MutationOperator.operators(upTo: .experimental).contains(.replaceStdlibSemantic))
    #expect(try MutationOperator.parse("flip-boolean, remove-call") == [.flipBoolean, .removeCall])
    #expect(
        try MutationOperator.parse("replace-stdlib-semantic, remove-switch-case")
            == [.replaceStdlibSemantic, .removeSwitchCase]
    )
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

@Test func `a generated schema silences lint plugins, keeps a shebang first, and maps diagnostics past the directive`()
    throws
{
    let source = "func f(_ a: Bool) -> Int { a ? 1 : 2 }\n"
    let found = try sites(source, [.swapTernary])
    let schema = try SchemaWriter.schema(source, mutations: found)
    #expect(schema.text.hasPrefix("// swiftlint:disable all\n"))
    let line = try #require(schema.lines[found[0].id])
    #expect(line.lowerBound == 2, "the directive is line 1; the function starts on line 2")
    let script = "#!/usr/bin/env swift\nlet x = true ? 1 : 2\n"
    let top = try SchemaWriter.schema(script, mutations: try sites(script, [.swapTernary]))
    #expect(top.text.hasPrefix("#!/usr/bin/env swift\n"))
    #expect(!top.text.contains("swiftlint:disable all"))
}

@Test func `the slowest mutants start first, and those without history keep their order after them`() throws {
    let source =
        "func f(_ a: Bool, _ b: Bool, _ c: Bool, _ d: Bool) -> Int { (a ? 1 : 2) + (b ? 1 : 2) + (c ? 1 : 2) + (d ? 1 : 2) }"
    let found = try sites(source, [.swapTernary])
    #expect(found.count == 4)
    let hints = [found[2].id: Int64(900), found[0].id: 50]
    let ordered = RunSession<BoundedExecutor>.longestFirst(found, hints: hints).map(\.id)
    #expect(ordered == [found[2].id, found[0].id, found[1].id, found[3].id])
    #expect(RunSession<BoundedExecutor>.longestFirst(found, hints: [:]).map(\.id) == found.map(\.id))
}

@Test func `progress numbers each decided mutant against the total and marks a reused one`() throws {
    let lines = Mutex<[String]>([])
    let reporter = ProgressReporter(total: 12) { line in lines.withLock { $0.append(line) } }
    let site = try #require(try sites("func f(_ a: Bool) -> Int { a ? 1 : 2 }", [.swapTernary]).first)
    reporter.report(MutationResult(mutation: site, verdict: .killed, reason: "killed"))
    var reused = MutationResult(mutation: site, verdict: .survived, reason: "kept")
    reused.reusedFrom = "an earlier run"
    reporter.report(reused)
    let written = lines.withLock { $0 }
    #expect(written[0] == "litmus: [ 1/12] killed              Sources/F.swift:1 swap-ternary")
    #expect(written[1].hasPrefix("litmus: [ 2/12] survived") && written[1].hasSuffix("(reused)"))
}

@Test
func `a manifest's local dependencies are read, and those outside the root are diagnosed with the command to run`()
    throws
{
    let manifest = """
        // swift-tools-version: 6.0
        let package = Package(name: "Lib", dependencies: [
            .package(path: "../Sibling"),
            .package(name: "Named", path: "Local/Inner"),
            .package(url: "https://example.com/x.git", from: "1.0.0"),
        ])
        """
    #expect(LocalDependencies.paths(inManifest: manifest) == ["../Sibling", "Local/Inner"])
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("litmus-deps-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }
    let library = base.appendingPathComponent("repo/Library")
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    try Data(manifest.utf8).write(to: library.appendingPathComponent("Package.swift"))
    try FileManager.default.createDirectory(
        at: base.appendingPathComponent("repo/Sibling"),
        withIntermediateDirectories: true
    )
    // Run from Library itself: its sibling is outside.
    let alone = try #require(LocalDependencies.diagnosis(root: library.path, packageDirectory: library.path))
    #expect(
        alone.contains(
            "litmus run \(URL(fileURLWithPath: base.path + "/repo").resolvingSymlinksInPath().path) --package-path Library"
        )
    )
    // Run from the repository with --package-path: the sibling is inside.
    #expect(LocalDependencies.diagnosis(root: base.path + "/repo", packageDirectory: library.path) == nil)
    #expect(LocalDependencies.commonAncestor(["/a/b/c", "/a/b/d", "/a/b"]) == "/a/b")
    #expect(LocalDependencies.commonAncestor(["/a", "/b"]) == "/")
}

@Test func `requested test targets must be ones the baseline ran, in either spelling`() throws {
    let known: Set<String> = ["App_Tests", "Core Tests", "Plain"]
    #expect(
        try RunSession<BoundedExecutor>.testTargets(["App-Tests", "Plain"], among: known) == ["App_Tests", "Plain"]
    )
    #expect(try RunSession<BoundedExecutor>.testTargets(["Core Tests"], among: known) == ["Core Tests"])
    let failure = #expect(throws: LitmusFailure.self) {
        try RunSession<BoundedExecutor>.testTargets(["Missing"], among: known)
    }
    #expect(failure?.description.contains("known: App_Tests, Core Tests, Plain") == true)
}

@Test func `call removal leaves value branches and guard exits alone, and mutates statement branches`() throws {
    let source = """
        func a(_ c: Bool) -> Int { if c { one() } else { two() } }
        func b(_ c: Bool) { let x = if c { one() } else { two() }; use(x) }
        func d(_ c: Int) { switch c { case 1: first(); default: second() } }
        func e(_ c: Bool) { if c { three() } else if !c { four() } }
        func f(_ x: Int?) { guard let x else { bail() }; use(x) }
        func g(_ x: Int?) { guard let x else { log(); return }; use(x) }
        """
    let found = Set(try sites(source, [.removeCall]).map(\.original))
    #expect(found == ["use(x)", "first()", "second()", "three()", "four()", "log()"], "\(found.sorted())")
}

@Test func `stable operators still mutate attribute arguments; the new ones do not`() throws {
    let source = "struct S { @Clamped(limit > 0 ? limit : 1) var v = 0; @Flag(true) var w = 0 }"
    let stable = try sites(source, MutationOperator.defaults)
    #expect(stable.map(\.operatorID) == [.swapTernary])
    let added = try sites(source, [.replaceRelational, .flipBoolean])
    #expect(added.isEmpty)
}

@Test func `compound assignment exchanges operators and skips string or array literal appends`() throws {
    let source = """
        func f(_ a: Int, _ b: Int) -> Int {
            var total = a
            total += b
            total -= 1
            total *= 2
            total /= 2
            total %= 3
            var text = "a"
            text += "b"
            var items: [Int] = []
            items += [1]
            return total
        }
        """
    let found = try sites(source, [.replaceArithmetic])
    let pairs = Set(found.map { "\($0.original) -> \($0.replacement)" })
    #expect(
        pairs == [
            "total += b -> total -= b",
            "total -= 1 -> total += 1",
            "total *= 2 -> total /= 2",
            "total /= 2 -> total *= 2",
            "total %= 3 -> total *= 3",
        ]
    )
}

@Test func `range boundary operator shifts upper bounds while preserving range type and skipping switch patterns`()
    throws
{
    let source = """
        func f(_ n: Int) -> Int {
            var sum = 0
            for i in 0..<n { sum += i }
            let closed = 1...20
            switch n {
            case 0..<5: return sum
            case 5...10: return closed.count
            default: return 0
            }
        }
        """
    let found = try sites(source, [.replaceRange])
    #expect(found.count == 2)
    #expect(found.contains { $0.original == "0..<n" && $0.replacement == "0..<((n) + 1)" })
    #expect(found.contains { $0.original == "1...20" && $0.replacement == "1...((20) - 1)" })
}

@Test func `unary negation removal mutates expressions and skips direct if, guard, while and ternary conditions`()
    throws
{
    let source = """
        func f(_ a: Bool, _ b: Bool) -> Bool {
            if !a { return !b }
            guard !a else { return false }
            while !b { break }
            let t = !a ? 1 : 2
            let combined = !a && !b
            return combined && t > 0
        }
        """
    let found = try sites(source, [.removeNegation])
    #expect(found.map(\.original) == ["!b", "!a", "!b"])
    #expect(found.map(\.replacement) == ["b", "a", "b"])
}

@Test func `nil coalescing replaces with fallback and skips Never-returning calls`() throws {
    let source = """
        func f(_ a: Int?, _ b: Int) -> Int {
            let x = a ?? b
            let y = a ?? fatalError("boom")
            return x + y
        }
        """
    let found = try sites(source, [.replaceNilCoalescing])
    #expect(found.map(\.original) == ["a ?? b"])
    #expect(found.map(\.replacement) == ["b"])
}

@Test
func `remove-call records skipped SwiftUI view-builder leaf elements and remove-view-element mutates only leaves`()
    throws
{
    let source = """
        struct CheckoutView {
            var error: String?
            var items: [Int]
            var body: some View {
                VStack {
                    Section("Order") {
                        Text("Title")
                        Button("Submit") { submit() }
                    }
                    if let error {
                        Text(error)
                    }
                    Text(items.map { format($0) }.joined())
                }
            }
            func submit() {}
            func format(_ n: Int) -> String { String(n) }
        }
        """
    let withCallRemoval = try MutationPlanner.discover(in: source, path: "View.swift", operators: [.removeCall])
    #expect(withCallRemoval.sites.isEmpty)
    #expect(withCallRemoval.skipped[MutationPlanner.skippedViewBuilderReason] == 4)

    let withViewRemoval = try MutationPlanner.discover(
        in: source,
        path: "View.swift",
        operators: [.removeViewElement]
    )
    #expect(withViewRemoval.skipped.isEmpty)
    #expect(
        Set(withViewRemoval.sites.map(\.original)) == [
            #"Text("Title")"#,
            #"Button("Submit") { submit() }"#,
            #"Text(error)"#,
            #"Text(items.map { format($0) }.joined())"#,
        ]
    )
    let schema = try SchemaWriter.schema(source, mutations: withViewRemoval.sites)
    for site in withViewRemoval.sites {
        #expect(schema.text.contains("if !__litmus_"))
        #expect(schema.text.contains("_\(site.id) { \(site.original) }"))
    }
}

@Test func `markdown report splits logic and UI scores and lists skipped view-builder sites`() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("litmus-md-\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: root) }
    try FileManager.default.createDirectory(atPath: root + "/Sources/App", withIntermediateDirectories: true)
    let source = """
        struct V {
            var body: some View {
                Text("a")
                Text("b")
            }
            func check(_ x: Int) -> Bool { x > 0 }
        }
        """
    let filePath = root + "/Sources/App/V.swift"
    try Data(source.utf8).write(to: URL(fileURLWithPath: filePath))

    let logicPlan = try await MutationPlanner.plan(root: root, operators: [.replaceRelational, .removeCall])
    #expect(logicPlan.skipped?[MutationPlanner.skippedViewBuilderReason] == 2)
    let entries = try await WorkspaceSnapshot.currentEntries(root)
    let snap = Digest.sha256(try ArtifactCodec.json(entries))
    let prov = RunProvenance(
        toolVersion: LitmusVersion.current,
        snapshotSHA256: snap,
        inputs: entries,
        driver: try BuildDriver(root: root, scheme: nil, destination: nil),
        toolchain: "test",
        startedAt: "2026-11-25T00:00:00Z",
        executionPolicy: RunArtifact.executionPolicy
    )
    var logicArtifact = RunArtifact(provenance: prov, plan: logicPlan)
    logicArtifact.complete = true
    logicArtifact.results = logicPlan.mutations.map {
        MutationResult(mutation: $0, verdict: .killed, reason: "killed")
    }
    let logicReport = try await MutationReport.make(logicArtifact, root: root, relative: true)
    let logicMd = MarkdownReport.render(logicReport, artifact: logicArtifact)
    #expect(
        logicMd.contains("Skipped: 2 SwiftUI view-builder leaf element(s) left alone (opt in: remove-view-element)")
    )
    #expect(logicArtifact.logicScore == nil && logicArtifact.uiScore == nil)

    let mixedPlan = try await MutationPlanner.plan(
        root: root,
        operators: [.replaceRelational, .removeViewElement]
    )
    var mixedArtifact = RunArtifact(provenance: prov, plan: mixedPlan)
    mixedArtifact.complete = true
    mixedArtifact.results = mixedPlan.mutations.map { m in
        MutationResult(
            mutation: m,
            verdict: m.operatorID.domain == .logic ? .killed : .survived,
            reason: m.operatorID.domain == .logic ? "killed" : "survived"
        )
    }
    let mixedReport = try await MutationReport.make(mixedArtifact, root: root, relative: true)
    let mixedMd = MarkdownReport.render(mixedReport, artifact: mixedArtifact)
    #expect(mixedMd.contains("Logic 100 % (2/2) · UI 0 % (0/2)"))
}

@Test func `modifier-chained view containers and chained action modifiers are excluded from remove-view-element`()
    throws
{
    let source = """
        struct SummaryView {
            var body: some View {
                VStack(alignment: .leading) {
                    Text("Subtotal")
                    Button("Save") { save() }.buttonStyle(.bordered)
                }
                .accessibilityElement(children: .combine)
                .onAppear {
                    load()
                    track()
                }
            }
            func save() {}
            func load() {}
            func track() {}
        }
        """
    let withCallRemoval = try MutationPlanner.discover(in: source, path: "Summary.swift", operators: [.removeCall])
    // The `.onAppear` action is ordinary code; `save()` is its `Button` action's only statement, its value.
    #expect(withCallRemoval.sites.map(\.original) == ["load()", "track()"])
    #expect(withCallRemoval.skipped[MutationPlanner.skippedViewBuilderReason] == 2)

    let withViewRemoval = try MutationPlanner.discover(
        in: source,
        path: "Summary.swift",
        operators: [.removeViewElement]
    )
    #expect(
        Set(withViewRemoval.sites.map(\.original)) == [
            #"Text("Subtotal")"#,
            #"Button("Save") { save() }.buttonStyle(.bordered)"#,
        ]
    )
}
