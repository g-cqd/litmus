import Foundation
import Testing

@testable import LitmusCore

@Suite struct PhaseETests {
    @Test func `nullify-optional-binding handles initialized, throwing, and shorthand bindings`() throws {
        let source = """
            func mayThrow() throws -> Int? { 1 }
            func f(_ a: Int?, _ b: String?) throws -> Int {
                if let x = a, let b {
                    guard let y = try mayThrow() else { return 0 }
                    return x + y + b.count
                }
                while var z = a { _ = z; break }
                return 0
            }
            """
        let sites = try MutationPlanner.mutations(in: source, path: "A.swift", operators: [.nullifyOptionalBinding])
        #expect(sites.count == 4)
        #expect(sites.contains { $0.original == "a" && $0.replacement == "nil" && $0.effectiveShape == .expression })
        #expect(
            sites.contains {
                $0.original == "let b"
                    && $0.replacement == "let b = \(SchemaWriter.clauseGuardPlaceholder) ? b : nil"
                    && $0.effectiveShape == .clause
            }
        )
        #expect(sites.contains { $0.original == "mayThrow()" && $0.replacement == "nil" })
        for batch in SchemaWriter.batches(sites) {
            _ = try SchemaWriter.schema(source, mutations: batch)
        }
    }

    @Test func `negate-is-empty skips direct conditions, prefix not, optional chains, and method calls`() throws {
        let source = """
            struct Box { var items: [Int]; func isEmpty() -> Bool { true } }
            func f(_ xs: [Int], _ opt: Box?) -> Bool {
                if xs.isEmpty { return true }
                if !xs.isEmpty { return false }
                let a = opt?.items.isEmpty ?? false
                let b = Box(items: xs).isEmpty()
                let c = xs.isEmpty && !a && b
                return xs.isEmpty
            }
            """
        let sites = try MutationPlanner.mutations(in: source, path: "A.swift", operators: [.negateIsEmpty])
        // Only `c = xs.isEmpty && ...` and `return xs.isEmpty` are mutated (`if xs.isEmpty` is negate-condition,
        // `!xs.isEmpty` is remove-negation, `opt?.items.isEmpty` is Bool?, `.isEmpty()` is a call).
        #expect(sites.count == 2)
        #expect(sites.allSatisfy { $0.original == "xs.isEmpty" && $0.replacement == "!(xs.isEmpty)" })
    }

    @Test func `skip-loop guards plain and filtered for-in loops without blocking body sites`() throws {
        let source = """
            func sum(_ xs: [Int]) -> Int {
                var total = 0
                for x in xs { total += x }
                for x in xs where x > 0 { total += x }
                return total
            }
            """
        let sites = try MutationPlanner.mutations(
            in: source,
            path: "A.swift",
            operators: [.skipLoop, .replaceArithmetic]
        )
        let loopSites = sites.filter { $0.operatorID == .skipLoop }
        #expect(loopSites.count == 2)
        #expect(loopSites.contains { $0.original == "xs" && $0.replacement.contains("where") })
        #expect(loopSites.contains { $0.original == "where x > 0" && $0.replacement.contains("where (x > 0) &&") })
        // Disjoint body arithmetic mutations share the first schema batch with both loop guards.
        let batches = SchemaWriter.batches(sites)
        #expect(batches.count == 1)
        _ = try SchemaWriter.schema(source, mutations: batches[0])
    }

    @Test func `swap-break-continue mutates loop jumps and skips non-loop switch breaks and labels`() throws {
        let source = """
            func scan(_ xs: [Int], _ tag: Int) -> Int {
                switch tag {
                case 0: break
                default: return -1
                }
                outer: for x in xs {
                    if x < 0 { continue }
                    if x == 0 { break }
                    if x == 9 { break outer }
                }
                return 1
            }
            """
        let sites = try MutationPlanner.mutations(in: source, path: "A.swift", operators: [.swapBreakContinue])
        #expect(sites.map(\.original) == ["continue", "break"])
    }

    @Test func `bitwise and unary-minus operators mutate non-literal expressions`() throws {
        let source = """
            func bits(_ a: Int, _ b: Int) -> Int {
                var mask = (a & b) | (a ^ b)
                mask &= (a << 1) | (b >> 1)
                let lit = -42
                let flt = -3.5
                return -mask + lit + Int(flt)
            }
            """
        let sites = try MutationPlanner.mutations(
            in: source,
            path: "A.swift",
            operators: [.replaceBitwise, .removeUnaryMinus]
        )
        #expect(
            sites.contains { $0.operatorID == .replaceBitwise && $0.original == "a & b" && $0.replacement == "a | b" }
        )
        #expect(
            sites.contains { $0.operatorID == .replaceBitwise && $0.original == "a ^ b" && $0.replacement == "a & b" }
        )
        #expect(
            sites.contains { $0.operatorID == .replaceBitwise && $0.original == "a << 1" && $0.replacement == "a >> 1" }
        )
        let unary = sites.filter { $0.operatorID == .removeUnaryMinus }
        #expect(unary.count == 1)
        #expect(unary.first?.original == "-mask" && unary.first?.replacement == "mask")
    }

    @Test func `computed properties and subscripts receive return mutations while closures isolate return types`()
        throws
    {
        let source = """
            struct Grid {
                var cells: [Int]
                var total: Int { cells.count }
                var label: String {
                    get { return "ok" }
                    set { if newValue.isEmpty { return } }
                }
                subscript(_ index: Int) -> Int { cells[index] }
                func outer() -> Int {
                    let names = cells.map { item in return "v\\(item)" }
                    return names.count
                }
            }
            """
        let sites = try MutationPlanner.mutations(
            in: source,
            path: "A.swift",
            operators: [.returnBoundary, .returnConstant]
        )
        #expect(sites.contains { $0.original == "cells.count" && $0.replacement == "(cells.count) + 1" })
        #expect(sites.contains { $0.original == "\"ok\"" && $0.replacement == "\"\"" })
        #expect(sites.contains { $0.original == "cells[index]" && $0.replacement == "0" })
        #expect(sites.contains { $0.original == "names.count" && $0.replacement == "0" })
        // Closure without an explicit return type must not inherit `outer() -> Int` onto `"v\\(item)"`.
        #expect(!sites.contains { $0.original.contains("v\\(item)") })
    }

    @Test func `census maps the Phase E2 candidate entries to their implemented operators`() throws {
        let source = """
            func demo(_ opt: Int?, _ xs: [Int]) -> Int {
                if let v = opt, !xs.isEmpty {
                    for x in xs {
                        if x == 0 { continue }
                        if x < 0 { break }
                        return -(v & x)
                    }
                }
                return 0
            }
            """
        let counted = try MutationCensus.count(source: source)
        #expect(counted["optional-binding-to-nil"]?.implementedBy == .nullifyOptionalBinding)
        #expect(counted["isEmpty-negation"]?.implementedBy == .negateIsEmpty)
        #expect(counted["loop-skip (for … where)"]?.implementedBy == .skipLoop)
        #expect(counted["break-continue-swap"]?.implementedBy == .swapBreakContinue)
        #expect(counted["bitwise-replace"]?.implementedBy == .replaceBitwise)
        #expect(counted["unary-minus-removal"]?.implementedBy == .removeUnaryMinus)
    }

    @Test func `per-operator summary reports generated, unviable rate, verdicts, accepted, score, and markdown table`()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("litmus-e4-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/Sources/App", withIntermediateDirectories: true)
        let source = """
            func check(_ a: Int?, _ b: Int) -> Bool {
                // @lm:accept:next replace-relational -- intentional
                if b < 0 { return false }
                if let x = a { return x > b }
                return false
            }
            """
        try Data(source.utf8).write(to: URL(fileURLWithPath: root + "/Sources/App/Check.swift"))
        let plan = try await MutationPlanner.plan(root: root, operators: [.nullifyOptionalBinding, .replaceRelational])
        let entries = try await WorkspaceSnapshot.currentEntries(root)
        let snap = Digest.sha256(try ArtifactCodec.json(entries))
        let prov = RunProvenance(
            toolVersion: LitmusVersion.current,
            snapshotSHA256: snap,
            inputs: entries,
            driver: try BuildDriver(root: root, scheme: nil, destination: nil),
            toolchain: "test",
            startedAt: "2026-11-27T00:00:00Z",
            executionPolicy: RunArtifact.executionPolicy
        )
        var artifact = RunArtifact(provenance: prov, plan: plan)
        artifact.complete = true
        artifact.results = plan.mutations.enumerated().map { idx, m in
            MutationResult(
                mutation: m,
                verdict: idx == 0 ? .killed : .survived,
                reason: idx == 0 ? "killed" : "survived",
                nanoseconds: 250_000_000
            )
        }
        let summaries = artifact.operatorSummaries
        #expect(summaries.map(\.operator) == ["nullify-optional-binding", "replace-relational"])
        let rel = try #require(summaries.first { $0.operator == "replace-relational" })
        #expect(rel.accepted == 2 && rel.generated == 4 && rel.viable == 4 && rel.unviable == 0)
        let report = try await MutationReport.make(artifact, root: root, relative: true)
        #expect(report.operators == summaries)
        let md = MarkdownReport.render(report, artifact: artifact)
        #expect(md.contains("### Results by operator"))
        #expect(md.contains("`nullify-optional-binding`"))
        let agent = AgentReport.make(artifact, root: root)
        #expect(agent.summary.operators == summaries)
        #expect(try MutationOperator.parse("all").contains(.nullifyOptionalBinding))
        #expect(!((try? MutationOperator.parse("all"))?.contains(.removeViewElement) ?? true))
    }

    #if os(macOS)
        @Test(.timeLimit(.minutes(2))) func `rendered Phase E2 schemas typecheck under Swift 6`() throws {
            let source = """
                struct Sample {
                    var items: [Int]
                    var count: Int { items.count }
                    func run(_ opt: Int?) throws -> Int {
                        guard let base = opt else { return 0 }
                        if let count = Optional(self.count) {
                            var acc = base ^ count
                            for item in items {
                                if item == 0 { continue }
                                if item < 0 { break }
                                acc |= (item << 1)
                            }
                            let emptyFlag = items.isEmpty
                            return emptyFlag ? -acc : acc
                        }
                        return 0
                    }
                }
                """
            let ops: Set<MutationOperator> = [
                .nullifyOptionalBinding, .negateIsEmpty, .skipLoop, .swapBreakContinue, .replaceBitwise,
                .removeUnaryMinus, .returnBoundary, .returnConstant,
            ]
            let sites = try MutationPlanner.mutations(in: source, path: "Sample.swift", operators: ops)
            #expect(sites.count >= 10)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("litmus-e2-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            for (index, batch) in SchemaWriter.batches(sites).enumerated() {
                let rendered = try SchemaWriter.schema(source, mutations: batch, token: "cafebabe")
                let file = dir.appendingPathComponent("batch-\(index).swift")
                try Data(rendered.text.utf8).write(to: file)
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                proc.arguments = ["swiftc", "-typecheck", "-swift-version", "6", "-parse-as-library", file.path]
                let pipe = Pipe()
                proc.standardError = pipe
                try proc.run()
                let err = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                proc.waitUntilExit()
                #expect(proc.terminationStatus == 0, "batch \(index) failed typecheck:\n\(err)")
            }
        }
    #endif
}
