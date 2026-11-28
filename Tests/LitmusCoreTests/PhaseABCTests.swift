import Foundation
import Testing

@testable import LitmusCore

@Suite("Phase A, B & C improvements")
struct PhaseABCTests {
    @Test(.timeLimit(.minutes(10))) func `all eight extended operators discover valid schematisable sites`() throws {
        let source = """
            struct Box { var count: Int }
            func run(_ items: [Int], _ name: String, _ box: Box?, _ queue: Runner) -> Int {
                let low = min(items.count, 10)
                let has = items.contains { $0 > 0 }
                let clean = name.lowercased().trimmingCharacters(in: .whitespaces)
                let maybe = box?.count ?? 0
                queue.async { SideEffect.fire() }
                queue.withLock { SideEffect.locked() }
                switch low {
                case 0: SideEffect.zero()
                case 1 where has: SideEffect.one()
                case let other: _ = other
                default: break
                }
                if clean.hasPrefix("a") { return maybe }
                return low
            }
            func performSync() {
                SideEffect.first()
                print("arid")
            }
            func onlyArid() {
                print("only logging")
            }
            func flag(_ x: Int) -> Bool { isReady(x) }
            func lookup(_ x: Int) -> String? { x > 0 ? "ok" : nil }
            func labels(_ x: Int) -> [String] { x > 0 ? ["a"] : ["b"] }
            """
        let ops: Set<MutationOperator> = [
            .replaceStdlibSemantic, .removeNormalization, .replaceOptionalChain,
            .returnBoundary, .returnConstant, .emptyBody, .emptyClosureBody, .removeSwitchCase,
        ]
        let found = try MutationPlanner.mutations(in: source, path: "Sources/S.swift", operators: ops)
        let byOp = Dictionary(grouping: found, by: \.operatorID)

        // replace-stdlib-semantic: min -> max, contains { } -> allSatisfy { }, hasPrefix -> hasSuffix;
        // element-form `(0...10).contains(x)` is left alone so it never fails to compile as `allSatisfy(x)`.
        let stdlib = Set((byOp[.replaceStdlibSemantic] ?? []).map(\.replacement))
        #expect(stdlib.contains("max(items.count, 10)"))
        #expect(stdlib.contains("items.allSatisfy { $0 > 0 }"))
        #expect(stdlib.contains(#"clean.hasSuffix("a")"#))
        #expect(
            try MutationPlanner.mutations(
                in: "func c(_ x: Int) -> Bool { (0...10).contains(x) }",
                path: "Sources/R.swift",
                operators: [.replaceStdlibSemantic]
            ).isEmpty
        )

        // remove-normalization: name.lowercased() -> name, and (...).trimmingCharacters(...) -> name.lowercased()
        let norm = Set((byOp[.removeNormalization] ?? []).map(\.replacement))
        #expect(norm.contains("name"))
        #expect(norm.contains("name.lowercased()"))

        // replace-optional-chain: box?.count -> box!.count
        #expect((byOp[.replaceOptionalChain] ?? []).map(\.replacement) == ["box!.count"])

        // return-boundary: Int returns + 1, [String] returns []
        let retBoundary = Set((byOp[.returnBoundary] ?? []).map(\.replacement))
        #expect(retBoundary.contains("(maybe) + 1"))
        #expect(retBoundary.contains("(low) + 1"))
        #expect(retBoundary.contains("[]"))

        // return-constant: Bool -> true/false, String? -> nil, Int -> 0
        let retConst = Set((byOp[.returnConstant] ?? []).map(\.replacement))
        #expect(retConst.contains("true") && retConst.contains("false"))
        #expect(retConst.contains("nil"))
        #expect(retConst.contains("0"))

        // empty-body: performSync() is mutated, onlyArid() is skipped
        let emptyBodies = byOp[.emptyBody] ?? []
        #expect(emptyBodies.count == 1)
        #expect(emptyBodies.first?.declaration == "performSync()")

        // empty-closure-body: queue.async { ... } is mutated, queue.withLock { ... } is skipped
        let emptyClosures = byOp[.emptyClosureBody] ?? []
        #expect(emptyClosures.count == 1)
        #expect(emptyClosures.first?.original == "SideEffect.fire()")

        // remove-switch-case: case 0 and case 1 where has get clause guards; `case let other` is skipped
        let switchCases = byOp[.removeSwitchCase] ?? []
        #expect(switchCases.count == 2)

        // All sites together render into a syntactically valid schema in a single batch!
        let batches = SchemaWriter.batches(found)
        #expect(batches.count == 1)
        let schema = try SchemaWriter.schema(source, mutations: batches[0])
        #expect(!schema.text.contains(SchemaWriter.clauseGuardPlaceholder))
        #expect(!schema.text.contains("import Foundation"))
    }

    @Test(.timeLimit(.minutes(10))) func `optional chaining on the left side of assignment is left alone`() throws {
        let source = "class C { var x = 0 }; func f(_ c: C?) -> Int { c?.x = 1; c?.x += 2; return c?.x ?? 0 }"
        let found = try MutationPlanner.mutations(
            in: source,
            path: "Sources/C.swift",
            operators: [.replaceOptionalChain]
        )
        #expect(found.count == 1)
        #expect(found.first?.replacement == "c!.x")
    }

    @Test(.timeLimit(.minutes(10)))
    func `aridCalls, excludeDeclarations and unknown accept directives work end-to-end`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("litmus-cfg-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/Sources/App", withIntermediateDirectories: true)
        try Data(
            """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(name: "App", targets: [.target(name: "App")])
            """.utf8
        ).write(to: URL(fileURLWithPath: root + "/Package.swift"))
        try Data(
            #"{"aridCalls": ["Analytics.track", "Telemetry"], "excludeDeclarations": ["*ForTesting"]}"#.utf8
        ).write(to: URL(fileURLWithPath: root + "/.litmus.json"))
        try Data(
            """
            func live(_ a: Int, _ b: Int) -> Bool {
                Analytics.track(a < b ? "lt" : "ge")
                Telemetry.send(a == b)
                SideEffect.save()
                // @lm:accept:next negate-conditon -- deliberate typo to test warning
                if a > b { return true }
                return false
            }
            func helperForTesting(_ a: Bool) -> Int {
                a ? 1 : 2
            }
            """.utf8
        ).write(to: URL(fileURLWithPath: root + "/Sources/App/App.swift"))

        let cfg = try LitmusConfiguration.load(root: root, explicit: nil)
        #expect(cfg.aridCalls == ["Analytics.track", "Telemetry"])
        #expect(cfg.excludeDeclarations == ["*ForTesting"])

        let plan = try await MutationPlanner.plan(
            root: root,
            operators: [.negateCondition, .swapTernary, .replaceRelational, .removeCall, .flipBoolean],
            aridCalls: cfg.aridCalls,
            excludeDeclarations: cfg.excludeDeclarations
        )
        // helperForTesting excluded; Analytics.track & Telemetry neither removed nor mutated inside arguments.
        #expect(plan.mutations.allSatisfy { $0.declaration == "live(_:_:)" })
        #expect(!plan.mutations.contains { $0.original.contains("Analytics") || $0.original.contains("Telemetry") })
        #expect(plan.mutations.contains { $0.original == "SideEffect.save()" && $0.operatorID == .removeCall })
        // Unknown directive operator produces a PlanNote warning and does NOT suppress `a > b`.
        #expect(plan.notes.contains { $0.reason.contains("unknown operator 'negate-conditon'") })
        // (`replace-relational` mutates it; its `!(a > b)` is the same mutant as `a <= b`, so it is planned once.)
        #expect(plan.mutations.contains { $0.original == "a > b" && $0.operatorID == .replaceRelational })
    }

    @Test(.timeLimit(.minutes(10)))
    func `guaranteed constant-folded integer overflows and duplicate literal/relational returns are skipped`()
        throws
    {
        let overflow =
            "func f(_ p: Int) -> Bool { p <= Int.max / 2 && p >= Int.min + 1 && (Int.max - 1) > 0 }"
        let arith = try MutationPlanner.mutations(
            in: overflow,
            path: "Sources/O.swift",
            operators: [.replaceArithmetic]
        )
        #expect(arith.isEmpty)

        let returns = """
            func zero() -> Int { return 0 }
            func cmp(_ a: Int, _ b: Int) -> Bool { a <= b }
            """
        let retSites = try MutationPlanner.mutations(
            in: returns,
            path: "Sources/Ret.swift",
            operators: [.returnBoundary, .returnConstant]
        )
        #expect(retSites.map(\.operatorID) == [.returnConstant])
        #expect(retSites.map(\.replacement) == ["1"])
    }

    @Test(.timeLimit(.minutes(10)))
    func `CompilerDiagnostics pinpoints the single offending mutant by column on nested single-line schemas`()
        throws
    {
        let source =
            "func f(_ points: Int, _ cap: Int) -> Int {\n    guard points <= cap / 2 else { return 0 }\n    return points\n}\n"
        let sites = try MutationPlanner.mutations(
            in: source,
            path: "Sources/L.swift",
            operators: [.negateCondition, .replaceRelational, .replaceArithmetic]
        )
        // Two relational mutants and `cap * 2`; `!(points <= cap / 2)` is `points > cap / 2`, planned once.
        #expect(sites.count >= 3)
        let schema = try SchemaWriter.schema(source, mutations: sites)
        let innerSite = try #require(sites.first { $0.replacement == "cap * 2" })
        let sub = try #require(schema.text.range(of: "cap * 2"))
        let prefix = schema.text[..<sub.lowerBound]
        let line = prefix.filter { $0 == "\n" }.count + 1
        let lineStart = prefix.lastIndex(of: "\n").map { schema.text.index(after: $0) } ?? schema.text.startIndex
        let col = schema.text[lineStart..<sub.lowerBound].utf8.count + 4
        let path = "/snap/Sources/L.swift"
        let msg = "\(path):\(line):\(col): error: synthetic error on inner expression\n"
        let out = ProcessOutput(exitStatus: 1, stdout: Array(msg.utf8), stderr: [], truncated: false, timedOut: false)
        let suspects = CompilerDiagnostics(out, snapshotRoot: "/snap").suspects(in: [path: schema])
        #expect(suspects == [innerSite.id])
    }

    @Test(.timeLimit(.minutes(10))) func `XcodeResultStream stops immediately on simulator host crash messages`() {
        let lines = """
            {"name":{"_value":"issueEmitted"},"structuredPayload":{"issue":{"message":{"_value":"Restarting after unexpected exit, crash, or test timeout in AppTests.testBoom()"}}}}
            """
        let scan = XcodeResultStream.scan(Array((lines + "\n").utf8))
        #expect(scan.crashed)
        #expect(!scan.failed)
    }

    @Test(.timeLimit(.minutes(10)))
    func
        `single-build nested schemas, strict memory safety with internal import Foundation, single-pass perTestReach and survivor recheck`()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("litmus-e2e-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let pkg = root.appendingPathComponent("Pkg")
        try FileManager.default.createDirectory(
            at: pkg.appendingPathComponent("Sources/Pkg"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: pkg.appendingPathComponent("Tests/PkgTests"),
            withIntermediateDirectories: true
        )
        try Data(
            """
            // swift-tools-version: 6.2
            import PackageDescription
            let package = Package(
                name: "Pkg",
                platforms: [.macOS(.v15)],
                targets: [
                    .target(
                        name: "Pkg",
                        swiftSettings: [
                            .enableUpcomingFeature("InternalImportsByDefault"),
                            .enableExperimentalFeature("StrictMemorySafety"),
                            .unsafeFlags(["-warnings-as-errors"]),
                        ]
                    ),
                    .testTarget(name: "PkgTests", dependencies: ["Pkg"]),
                ]
            )
            """.utf8
        ).write(to: pkg.appendingPathComponent("Package.swift"))

        // File 1 uses `internal import Foundation` — previously injecting `import Foundation` in File 2 failed to build!
        try Data(
            """
            internal import Foundation
            public func rootPath() -> String { URL(fileURLWithPath: "/tmp").path }
            """.utf8
        ).write(to: pkg.appendingPathComponent("Sources/Pkg/Found.swift"))

        // File 2 has NO `import Foundation`, nested boolean expressions, stdlib semantic swap, and shared state across tests.
        try Data(
            """
            public enum Gate {
                nonisolated(unsafe) public static var counter = 0
                public static func decide(_ a: Bool, _ b: Bool, _ c: Bool) -> Bool {
                    a && (b || c)
                }
                public static func clamp(_ x: Int) -> Int {
                    min(x, 10)
                }
                public static func bump() {
                    counter += 1
                }
            }
            """.utf8
        ).write(to: pkg.appendingPathComponent("Sources/Pkg/Gate.swift"))

        try Data(
            """
            import Testing
            import Pkg

            @Suite(.serialized)
            struct GateTests {
                @Test(.timeLimit(.minutes(10))) func booleanLogic() {
                    #expect(Gate.decide(true, true, false) == true)
                    #expect(Gate.decide(true, false, true) == true)
                    #expect(Gate.decide(true, false, false) == false)
                    #expect(Gate.decide(false, true, true) == false)
                }
                @Test(.timeLimit(.minutes(10))) func clamping() {
                    #expect(Gate.clamp(3) == 3)
                    #expect(Gate.clamp(25) == 10)
                }
                @Test(.timeLimit(.minutes(10))) func stepOneReachesBumpWithoutAsserting() {
                    Gate.counter = 0
                    Gate.bump()
                }
                @Test(.timeLimit(.minutes(10))) func stepTwoAssertsSharedStateWithoutReachingBump() {
                    #expect(Gate.counter == 1)
                }
            }
            """.utf8
        ).write(to: pkg.appendingPathComponent("Tests/PkgTests/GateTests.swift"))

        let driver = try BuildDriver(root: pkg.path, scheme: nil, destination: nil)
        var options = RunOptions()
        options.operators = [.replaceLogical, .replaceStdlibSemantic, .emptyBody]
        options.perTestReach = true
        options.recheckSurvivors = true
        options.baselineRepetitions = 1
        options.jobs = 2

        let out = root.appendingPathComponent("run").path
        let artifact = try await MutationRunner(executor: BoundedExecutor()).run(
            driver: driver,
            outputDirectory: out,
            options: options
        )
        #expect(artifact.isSuccessfulExecution)
        // Nested expressions + emptyBody + stdlib swap all compiled in ONE single schema build!
        #expect(artifact.cost?.builds == 1)
        // Every mutant (decide's nested &&/||, clamp's min->max, and bump's emptyBody via survivor recheck!) is killed!
        #expect(artifact.results.allSatisfy { $0.verdict == .killed })
        // Single-pass FIFO perTestReach attributed clamp's mutant specifically to `clamping()`, not `booleanLogic()`.
        let clampMutant = try #require(artifact.results.first { $0.mutation.operatorID == .replaceStdlibSemantic })
        let clampReach = artifact.perTestReach?[clampMutant.mutation.id] ?? []
        #expect(clampReach.contains { $0.contains("clamping") })
        #expect(!clampReach.contains { $0.contains("booleanLogic") })
    }
}
