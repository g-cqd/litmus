import Foundation
import ProjectModel
import SourceCorpus
import Synchronization
import Testing

@testable import LitmusCore

private func fixture(_ source: String = "public func choice(_ value: Bool) -> Int { value ? 1 : 2 }") throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("litmus-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("input/Sources/Example"),
        withIntermediateDirectories: true
    )
    try Data(
        "// swift-tools-version: 6.4\nimport PackageDescription\nlet package = Package(name: \"Example\", targets: [.target(name: \"Example\")])"
            .utf8
    )
    .write(to: root.appendingPathComponent("input/Package.swift"))
    try Data(source.utf8).write(to: root.appendingPathComponent("input/Sources/Example/F.swift"))
    return root
}

@Test func `snapshot edits cannot change original and traversal is rejected`() async throws {
    let base = try fixture()
    defer { try? FileManager.default.removeItem(at: base) }
    let source = base.appendingPathComponent("input").path
    let snapshot = try await WorkspaceSnapshot.create(
        source: source,
        destination: base.appendingPathComponent("copy").path
    )
    let path = try snapshot.path(for: "Sources/Example/F.swift")
    try Data("changed".utf8).write(to: URL(fileURLWithPath: path))
    #expect(try String(contentsOfFile: source + "/Sources/Example/F.swift", encoding: .utf8).contains("choice"))
    #expect(throws: (any Error).self) { try snapshot.path(for: "../input/Package.swift") }
    await #expect(throws: (any Error).self) {
        try await WorkspaceSnapshot.create(source: source, destination: source + "/inside")
    }
}

@Test func `snapshot leaves a symlink out, lists it, and never follows it`() async throws {
    let base = try fixture()
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(atPath: base.path + "/input/.claude", withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: base.path + "/input/.claude/skills", withDestinationPath: "/tmp")
    let snapshot = try await WorkspaceSnapshot.create(source: base.path + "/input", destination: base.path + "/copy")
    #expect(snapshot.skippedLinks == [".claude/skills"])
    #expect(!snapshot.entries.contains { $0.path.hasPrefix(".claude") })
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: base.path + "/copy/.claude/skills")) == nil)
    #expect(throws: (any Error).self) { try snapshot.path(for: ".claude/skills") }
}

/// Simulates SwiftPM: builds fail when a poisoned replacement is present, tests write xUnit and activation markers.
private final class FakeExecutor: ProcessExecutor {
    enum Active: Sendable { case fail, pass, crash, hang }
    struct Config: Sendable {
        var failsBaseline = false
        var swiftTestingOnly = false
        var reach = true
        var markActive = true
        var active = Active.fail
        var poison: String?
        var poisonDiagnostic = true
        /// Lines between the poisoned replacement and the error reported (a flow error at the end of a function).
        var diagnosticOffset = 0
        /// How long each build takes.
        var buildDelay: Duration = .zero
    }
    let config: Config
    let calls = Mutex<[[String: String]]>([])
    let deadlines = Mutex<[Int]>([])
    let reports = Mutex<[String]>([])
    let builds = Mutex(0)
    init(_ config: Config = Config()) { self.config = config }

    private func sources(_ directory: String) -> [String] {
        let enumerator = FileManager.default.enumerator(atPath: directory + "/Sources")
        return (enumerator?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".swift") }
            .map { directory + "/Sources/" + $0 }
    }

    func execute(
        _ command: ToolCommand,
        directory: String,
        environment: [String: String],
        timeout: Int,
        supervision: Supervision
    ) async throws -> ProcessOutput {
        if command.arguments.contains("--build-tests") {
            builds.withLock { $0 += 1 }
            if config.buildDelay > .zero { try await Task.sleep(for: config.buildDelay) }
            if let poison = config.poison {
                for path in sources(directory) {
                    let text = try String(contentsOfFile: path, encoding: .utf8)
                    let lines = text.components(separatedBy: "\n")
                    if let line = lines.firstIndex(where: { $0.contains(poison) }) {
                        let message =
                            config.poisonDiagnostic ? "\(path):\(line + 1):5: error: poisoned" : "error: failed"
                        return ProcessOutput(
                            exitStatus: 1,
                            stdout: Array(message.utf8),
                            stderr: [],
                            truncated: false,
                            timedOut: false
                        )
                    }
                }
            }
            return ProcessOutput(exitStatus: 0, stdout: [], stderr: [], truncated: false, timedOut: false)
        }
        if command.arguments.first == "git" {
            // A clean, tracked work tree.
            return ProcessOutput(exitStatus: 0, stdout: [], stderr: [], truncated: false, timedOut: false)
        }
        guard let index = command.arguments.firstIndex(of: "--xunit-output") else {
            return ProcessOutput(
                exitStatus: 0,
                stdout: Array("fake toolchain".utf8),
                stderr: [],
                truncated: false,
                timedOut: false
            )
        }
        calls.withLock { $0.append(environment) }
        deadlines.withLock { $0.append(timeout) }
        reports.withLock { $0.append(URL(fileURLWithPath: command.arguments[index + 1]).lastPathComponent) }
        let active = !(environment[ActivationEnvironment.activeID] ?? "").isEmpty
        if config.reach, !active || config.markActive,
            let markers = environment[ActivationEnvironment.coverageDirectory]
        {
            for path in sources(directory) {
                let text = try String(contentsOfFile: path, encoding: .utf8)
                for match in text.matches(of: /_reach\("([0-9a-f]{16})"\)/) {
                    FileManager.default.createFile(atPath: markers + "/" + match.1, contents: nil)
                }
            }
        }
        let outcome: Active = active ? config.active : (config.failsBaseline ? .fail : .pass)
        switch outcome {
        case .hang: return ProcessOutput(exitStatus: 124, stdout: [], stderr: [], truncated: false, timedOut: true)
        case .crash:
            var output = ProcessOutput(exitStatus: 139, stdout: [], stderr: [], truncated: false, timedOut: false)
            output.terminationSignal = 11
            return output
        case .fail, .pass:
            let fail = outcome == .fail
            let xml =
                "<testsuites><testsuite><testcase name=\"choice\">\(fail ? "<failure message=\"assertion\"/>" : "")</testcase></testsuite></testsuites>"
            let requested = command.arguments[index + 1]
            let report = config.swiftTestingOnly ? String(requested.dropLast(4)) + "-swift-testing.xml" : requested
            try Data(xml.utf8).write(to: URL(fileURLWithPath: report))
            return ProcessOutput(exitStatus: fail ? 1 : 0, stdout: [], stderr: [], truncated: false, timedOut: false)
        }
    }
}

private func options(jobs: Int = 2) -> RunOptions {
    var options = RunOptions()
    options.harness = .swiftTest
    options.jobs = jobs
    options.timeoutCap = 10
    options.minimumTimeout = 3
    return options
}

private func run(
    _ executor: FakeExecutor,
    source: String? = nil,
    configure: (inout RunOptions) -> Void = { _ in }
) async throws -> (RunArtifact, URL) {
    let base = try source.map(fixture) ?? fixture()
    let driver = try BuildDriver(root: base.path + "/input", scheme: nil, destination: nil)
    var options = options()
    configure(&options)
    let artifact = try await MutationRunner(executor: executor).run(
        driver: driver,
        outputDirectory: base.path + "/run",
        options: options
    )
    return (artifact, base)
}

@Test(arguments: [false, true]) func `a kill needs the mutant's own activation and a passing control`(
    swiftTestingOnly: Bool
) async throws {
    let executor = FakeExecutor(.init(swiftTestingOnly: swiftTestingOnly))
    let (result, base) = try await run(executor)
    defer { try? FileManager.default.removeItem(at: base) }
    #expect(result.isSuccessfulExecution)
    #expect(result.results.map(\.verdict) == [.killed])
    let active = try #require(result.results.first?.mutation.id)
    // The inactive schema is the baseline and the control at once (ADR 0007); `swift test` cannot select tests, so a
    // targeted confirmation reruns the whole suite alone.
    #expect(executor.calls.withLock { $0.map { $0[ActivationEnvironment.activeID] ?? "" } } == ["", active, active])
    #expect(executor.builds.withLock { $0 } == 1)
    #expect(result.policy?.baselineBuild == "inactive-schema")
    #expect(result.policy?.killConfirmation == .targeted)
    #expect(!FileManager.default.fileExists(atPath: base.path + "/run/workspace"))
    #expect(try ArtifactCodec.read(RunArtifact.self, path: base.path + "/run/run.pb").results.first?.verdict == .killed)
    let journal = try ResultJournal.read(path: base.path + "/run/results.journal")
    #expect(journal.results.map(\.verdict) == [.killed])
    #expect(!journal.truncated)
}

@Test func `with no kill confirmation, the first failure after activation is the kill`() async throws {
    let executor = FakeExecutor()
    let base = try fixture()
    defer { try? FileManager.default.removeItem(at: base) }
    var unconfirmed = options()
    unconfirmed.killConfirmation = .none
    let result = try await MutationRunner(executor: executor).run(
        driver: try BuildDriver(root: base.path + "/input", scheme: nil, destination: nil),
        outputDirectory: base.path + "/run",
        options: unconfirmed
    )
    #expect(result.results.map(\.verdict) == [.killed])
    #expect(executor.calls.withLock { $0.count } == 2)
}

@Test func `a mutant the control never reached is no coverage, and is not run`() async throws {
    let executor = FakeExecutor(.init(reach: false))
    let (result, base) = try await run(executor)
    defer { try? FileManager.default.removeItem(at: base) }
    #expect(result.results.map(\.verdict) == [.noCoverage])
    #expect(executor.calls.withLock { $0.count } == 1)
    #expect(result.score.percent == 0)
}

@Test func `a failure without activation is rerun and never counts as a kill`() async throws {
    let executor = FakeExecutor(.init(markActive: false))
    let (result, base) = try await run(executor)
    defer { try? FileManager.default.removeItem(at: base) }
    #expect(result.results.map(\.verdict) == [.infrastructureError])
    #expect(executor.calls.withLock { $0.count } == 3)
    #expect(!result.isSuccessfulExecution)
}

@Test func `a repeated crash after activation is a crash kill`() async throws {
    let executor = FakeExecutor(.init(active: .crash))
    let (result, base) = try await run(executor)
    defer { try? FileManager.default.removeItem(at: base) }
    #expect(result.results.map(\.verdict) == [.crashed])
    #expect(result.score.percent == 100)
}

@Test func `timeouts are rerun alone, after the parallel pass, with twice the deadline`() async throws {
    let executor = FakeExecutor(.init(active: .hang))
    let (result, base) = try await run(executor, source: twoSites)
    defer { try? FileManager.default.removeItem(at: base) }
    #expect(result.results.map(\.verdict) == [.timeout, .timeout])
    #expect(result.policy?.deadline == 3)
    // `swift test` allows one worker: no contention allowance on the first runs, twice the deadline on the reruns.
    #expect(result.policy?.parallelDeadline == 3)
    #expect(executor.deadlines.withLock { Array($0.suffix(4)) } == [3, 3, 6, 6])
    let names = executor.reports.withLock { Array($0.suffix(4)) }
    #expect(names.prefix(2).allSatisfy { !$0.contains("-rerun") })
    #expect(names.suffix(2).allSatisfy { $0.contains("-rerun") })
}

private let twoSites = """
    public func a(_ x: Bool) -> Int { x ? 1 : 2 }
    public func b(_ y: Bool) -> Int { y ? 3 : 4 }
    """

@Test func `a mutant that does not compile is isolated by its diagnostic; the others still run`() async throws {
    let executor = FakeExecutor(.init(poison: "!(y)"))
    let (result, base) = try await run(executor, source: twoSites)
    defer { try? FileManager.default.removeItem(at: base) }
    let verdicts = Dictionary(uniqueKeysWithValues: result.results.map { ($0.mutation.original, $0.verdict) })
    #expect(verdicts == ["x": .killed, "y": .unviable])
    #expect(result.isSuccessfulExecution)
    // The first schema did not build: the unmutated build told a sound subject from an unviable mutant, and became
    // the baseline. Schema (x, y), unmutated, schema (x), schema (y).
    #expect(executor.builds.withLock { $0 } == 4)
    #expect(result.policy?.baselineBuild == "unmutated (the first schema did not build)")
}

@Test func `the unmutated baseline is still available, at one build and one suite run more`() async throws {
    let executor = FakeExecutor()
    let (result, base) = try await run(executor) { $0.inactiveSchemaBaseline = false }
    defer { try? FileManager.default.removeItem(at: base) }
    let active = try #require(result.results.first?.mutation.id)
    #expect(result.results.map(\.verdict) == [.killed])
    #expect(
        executor.calls.withLock { $0.map { $0[ActivationEnvironment.activeID] ?? "" } } == ["", "", active, active]
    )
    #expect(executor.builds.withLock { $0 } == 2)
    #expect(result.policy?.baselineBuild == "unmutated")
}

@Test func `a subject that does not build stops the run even when the schema is the baseline`() async throws {
    let executor = FakeExecutor(.init(poison: "choice"))
    let (base, driver) = try { () throws -> (URL, BuildDriver) in
        let base = try fixture()
        return (base, try BuildDriver(root: base.path + "/input", scheme: nil, destination: nil))
    }()
    defer { try? FileManager.default.removeItem(at: base) }
    await #expect(throws: LitmusFailure.self) {
        try await MutationRunner(executor: executor).run(
            driver: driver,
            outputDirectory: base.path + "/run",
            options: options()
        )
    }
    // The schema failed, then the unmutated build: no verdict.
    #expect(executor.builds.withLock { $0 } == 2)
    let checkpoint = try ArtifactCodec.read(RunArtifact.self, path: base.path + "/run/run.json")
    #expect(checkpoint.results.map(\.verdict) == [.notRun])
}

@Test func `without a compiler error in the mutant's file, a failing build is not called unviable`() async throws {
    let executor = FakeExecutor(.init(poison: "!(y)", poisonDiagnostic: false))
    let (result, base) = try await run(executor, source: twoSites)
    defer { try? FileManager.default.removeItem(at: base) }
    let verdicts = Dictionary(uniqueKeysWithValues: result.results.map { ($0.mutation.original, $0.verdict) })
    #expect(verdicts == ["x": .killed, "y": .infrastructureError])
}

@Test func `failed baseline preserves an incomplete checkpoint with no kills`() async throws {
    let base = try fixture()
    defer { try? FileManager.default.removeItem(at: base) }
    let driver = try BuildDriver(root: base.path + "/input", scheme: nil, destination: nil)
    await #expect(throws: (any Error).self) {
        try await MutationRunner(executor: FakeExecutor(.init(failsBaseline: true))).run(
            driver: driver,
            outputDirectory: base.path + "/run",
            options: options()
        )
    }
    let checkpoint = try ArtifactCodec.read(RunArtifact.self, path: base.path + "/run/run.json")
    #expect(!checkpoint.complete)
    #expect(checkpoint.results.map(\.verdict) == [.notRun])
    #expect(!checkpoint.isSuccessfulExecution)
}

@Test func `a lone mutant whose error lands elsewhere in its own file is unviable`() async throws {
    let executor = FakeExecutor(.init(poison: "!(y)", diagnosticOffset: 3))
    let (result, base) = try await run(executor, source: twoSites)
    defer { try? FileManager.default.removeItem(at: base) }
    let verdicts = Dictionary(uniqueKeysWithValues: result.results.map { ($0.mutation.original, $0.verdict) })
    #expect(verdicts == ["x": .killed, "y": .unviable])
}

@Test func `a directory is removed, and a missing one counts as removed`() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("litmus-remove-\(UUID().uuidString)")
        .path
    try FileManager.default.createDirectory(atPath: directory + "/a/b", withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: directory + "/a/b/f", contents: Data("x".utf8))
    #expect(MutationRunner<BoundedExecutor>.remove(directory))
    #expect(!FileManager.default.fileExists(atPath: directory))
    #expect(MutationRunner<BoundedExecutor>.remove(directory))
}

private let scopedSites = """
    public func choice(_ value: Bool) -> Int {
        value ? 1 : 2
    }
    public func other(_ a: Bool, _ b: Bool) -> Bool {
        a && b
    }
    """

private func scope(_ files: [String: [ClosedRange<Int>]], _ breadth: ChangeScope.Breadth = .lines) -> ChangeScope {
    ChangeScope(changed: ChangedLines(files: files), breadth: breadth, source: "test diff", digest: "d")
}

@Test func `a change that reaches no site ends before any copy, build or toolchain query`() async throws {
    let executor = FakeExecutor()
    let (artifact, base) = try await run(executor, source: scopedSites) { options in
        options.scope = scope(["Sources/Example/F.swift": [4...4], "README.md": [1...3]])
    }
    defer { try? FileManager.default.removeItem(at: base) }
    #expect(artifact.complete && artifact.isSuccessfulExecution)
    #expect(artifact.results.isEmpty)
    #expect(artifact.plan.scope?.swiftFiles == 1)
    #expect(executor.builds.withLock { $0 } == 0)
    #expect(executor.calls.withLock { $0.isEmpty })
    #expect(!FileManager.default.fileExists(atPath: base.path + "/run/workspace"))
    #expect(FileManager.default.fileExists(atPath: base.path + "/run/run.pb"))
    #expect(artifact.provenance.toolchain.hasPrefix("not invoked"))
    // The report checks the inventory as it does after a full run.
    let report = try await MutationReport.make(artifact, root: base.path + "/input")
    #expect(report.successfulExecution)
}

@Test func `a change runs the sites on its changed lines only, or its files with those lines first`() async throws {
    let (lines, base) = try await run(FakeExecutor(), source: scopedSites) { options in
        options.scope = scope(["Sources/Example/F.swift": [5...5]])
    }
    defer { try? FileManager.default.removeItem(at: base) }
    #expect(lines.results.map(\.mutation.original) == ["a && b"])
    #expect(lines.results.allSatisfy { $0.verdict == .killed })

    let (files, other) = try await run(FakeExecutor(), source: scopedSites) { options in
        options.scope = scope(["Sources/Example/F.swift": [5...5]], .files)
    }
    defer { try? FileManager.default.removeItem(at: other) }
    #expect(files.plan.mutations.map(\.original) == ["a && b", "value"])
    #expect(files.plan.scope?.onChangedLines == [files.plan.mutations[0].id])
}

@Test func `a scoped plan reads only the changed Swift files and notes stale or excluded ones`() async throws {
    let base = try fixture(scopedSites)
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.path + "/input"
    try Data("let x = true ? 1 : 2\n".utf8).write(to: URL(fileURLWithPath: root + "/Sources/Example/G.swift"))
    let plan = try await MutationPlanner.plan(
        root: root,
        exclude: ["G.swift"],
        scope: scope(["Sources/Example/F.swift": [2...2], "Sources/Example/G.swift": [1...1], "Gone.swift": [1...1]])
    )
    #expect(plan.mutations.map(\.original) == ["value"])
    #expect(plan.analyzedFiles == 1)
    #expect(plan.notes.contains { $0.path == "Sources/Example/G.swift" && !$0.isDegraded })
    #expect(plan.notes.contains { $0.path == "Gone.swift" && $0.isDegraded })
}

@Test func `a multi-line site is in scope when any of its lines changed`() {
    let site = Mutation(
        id: "0000000000000001",
        path: "A.swift",
        line: 10,
        column: 5,
        operatorID: .replaceLogical,
        start: 0,
        end: 10,
        original: "a\n    && b\n    && c",
        replacement: "x",
        sourceFingerprint: "f"
    )
    #expect(site.endLine == 12)
    #expect(scope(["A.swift": [12...12]]).priority(of: site) == 0)
    #expect(scope(["A.swift": [13...20]]).priority(of: site) == nil)
    #expect(scope(["A.swift": [13...20]], .files).priority(of: site) == 1)
    #expect(scope(["B.swift": [10...10]], .files).priority(of: site) == nil)
}

@Test func `a run reports its own cost: builds, test runs, CPU, memory and disk`() async throws {
    let executor = FakeExecutor()
    let (artifact, base) = try await run(executor)
    defer { try? FileManager.default.removeItem(at: base) }
    let cost = try #require(artifact.cost)
    #expect(cost.builds == executor.builds.withLock { $0 })
    #expect(cost.testRuns == executor.calls.withLock { $0.count })
    #expect(cost.wallSeconds > 0 && cost.litmusPeakRSSMiB > 0)
    #expect(cost.runDirectoryMiB > 0 && cost.runDirectoryMiB >= cost.workspaceMiB)
}

// MARK: - Reuse and budgets (ADR 0007)

@Test func `a result store reuses every verdict of an unchanged subject without building`() async throws {
    let base = try fixture(twoSites)
    defer { try? FileManager.default.removeItem(at: base) }
    let driver = try BuildDriver(root: base.path + "/input", scheme: nil, destination: nil)
    var stored = options()
    stored.resultStore = base.path + "/store"
    let first = try await MutationRunner(executor: FakeExecutor()).run(
        driver: driver,
        outputDirectory: base.path + "/run1",
        options: stored
    )
    #expect(first.results.allSatisfy { $0.reusedFrom == nil && $0.reuseKey != nil })
    let again = FakeExecutor()
    let second = try await MutationRunner(executor: again).run(
        driver: driver,
        outputDirectory: base.path + "/run2",
        options: stored
    )
    #expect(second.results.map(\.verdict) == first.results.map(\.verdict))
    #expect(second.results.allSatisfy { $0.reusedFrom == first.provenance.runID })
    #expect(again.builds.withLock { $0 } == 0 && again.calls.withLock { $0.isEmpty })
    #expect(second.reuse?.fromStore == 2 && second.isSuccessfulExecution)
    #expect(try await MutationReport.make(second, root: base.path + "/input").successfulExecution)

    // Any change in the package (its closure) is a miss: the verdicts are decided again.
    try Data("// changed\n".utf8).write(to: URL(fileURLWithPath: base.path + "/input/Sources/Example/Other.swift"))
    let changed = FakeExecutor()
    let third = try await MutationRunner(executor: changed).run(
        driver: driver,
        outputDirectory: base.path + "/run3",
        options: stored
    )
    #expect(third.results.allSatisfy { $0.reusedFrom == nil })
    #expect(changed.builds.withLock { $0 } > 0)
}

@Test func `a key changes with the closure, the options and the toolchain, and not with lines moving`() throws {
    let base = try fixture(twoSites)
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.path + "/input"
    let mutations = try MutationPlanner.mutations(in: twoSites, path: "Sources/Example/F.swift")
    func key(
        _ entries: [SnapshotEntry],
        mode: ReuseContext.Mode = .closure,
        toolchain: String = "t",
        failFast: Bool = true,
        mutation: Mutation? = nil
    ) throws -> String {
        let context = try ReuseContext(
            mode: mode,
            root: root,
            entries: entries,
            wholeSnapshot: "whole",
            mutations: mutations,
            closureKnown: true,
            context: ReuseContextInputs(
                toolVersion: "v",
                executionPolicy: "p",
                toolchain: toolchain,
                driver: try BuildDriver(root: root, scheme: nil, destination: nil),
                harness: "automatic",
                failFast: failFast,
                killConfirmation: "targeted",
                memoryLimitMiB: 1,
                timeoutCap: 1,
                timeoutFactor: 1,
                minimumTimeout: 1,
                baselineRepetitions: 1,
                suiteWidth: nil,
                selectTestTargets: true,
                background: false,
                excluded: []
            )
        )
        return context.key(mutation ?? mutations[0])
    }
    let entries = [
        SnapshotEntry(path: "Package.swift", sha256: "1"), SnapshotEntry(path: "Sources/Example/F.swift", sha256: "2"),
        SnapshotEntry(path: "Tests/ExampleTests/T.swift", sha256: "3"),
    ]
    let reference = try key(entries)
    #expect(try key(entries) == reference)
    #expect(
        try key(entries.map { $0.path.hasPrefix("Tests") ? SnapshotEntry(path: $0.path, sha256: "4") : $0 })
            != reference
    )
    #expect(try key(entries, toolchain: "other") != reference)
    #expect(try key(entries, failFast: false) != reference)
    #expect(try key(entries, mutation: mutations[1]) != reference)
    // Declaration keys: a change elsewhere in the module's sources keeps the key; a test change does not.
    let declaration = try key(entries, mode: .declaration)
    #expect(
        try key(
            entries.map { $0.path.hasSuffix("F.swift") ? SnapshotEntry(path: $0.path, sha256: "9") : $0 },
            mode: .declaration
        ) == declaration
    )
    #expect(
        try key(
            entries.map { $0.path.hasPrefix("Tests") ? SnapshotEntry(path: $0.path, sha256: "4") : $0 },
            mode: .declaration
        ) != declaration
    )
}

@Test func `a store record that fails verification is a miss, never a verdict`() async throws {
    let base = try fixture()
    defer { try? FileManager.default.removeItem(at: base) }
    let mutation = try #require(try MutationPlanner.mutations(in: "let x = true ? 1 : 2", path: "A.swift").first)
    let result = MutationResult(mutation: mutation, verdict: .survived, reason: "every test passed")
    let store = try ResultStore(
        directory: base.path + "/store",
        readOnly: false,
        limitMiB: 1,
        forbidden: base.path + "/input"
    )
    try store.put("k1", result, runID: "run")
    #expect(store.lookup("k1", mutation: mutation)?.result.verdict == .survived)
    // Tampered bytes: the digest no longer matches.
    let file = base.path + "/store/v1/records/k1/k1.rec"
    var bytes = try Data(contentsOf: URL(fileURLWithPath: file))
    bytes[bytes.count / 2] ^= 0xFF
    try bytes.write(to: URL(fileURLWithPath: file))
    #expect(store.lookup("k1", mutation: mutation) == nil)
    #expect(!store.notes.isEmpty)
    // Signed records: another key cannot forge or read them as valid.
    let signed = try ResultStore(
        directory: base.path + "/store",
        readOnly: false,
        limitMiB: 1,
        forbidden: base.path + "/input",
        secret: "s1"
    )
    try signed.put("k2", result, runID: "run")
    #expect(signed.lookup("k2", mutation: mutation) != nil)
    let other = try ResultStore(
        directory: base.path + "/store",
        readOnly: true,
        limitMiB: 1,
        forbidden: base.path + "/input",
        secret: "s2"
    )
    #expect(other.lookup("k2", mutation: mutation) == nil)
    // Read-only stores do not write; a non-empty directory that is not a store is refused; the subject is refused.
    try other.put("k3", result, runID: "run")
    #expect(!FileManager.default.fileExists(atPath: base.path + "/store/v1/records/k3/k3.rec"))
    #expect(throws: LitmusFailure.self) {
        try ResultStore(directory: base.path + "/input", readOnly: false, limitMiB: 1, forbidden: base.path + "/input")
    }
    #expect(throws: LitmusFailure.self) {
        try ResultStore(directory: base.path, readOnly: false, limitMiB: 1, forbidden: "/elsewhere")
    }
}

@Test func `a store past its limit evicts the least recently used records`() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("litmus-evict-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let mutation = try #require(try MutationPlanner.mutations(in: "let x = true ? 1 : 2", path: "A.swift").first)
    let result = MutationResult(mutation: mutation, verdict: .killed, reason: String(repeating: "r", count: 200_000))
    let store = try ResultStore(directory: base.path, readOnly: false, limitMiB: 1, forbidden: "/elsewhere")
    for index in 0..<8 { try store.put("key\(index)", result, runID: "run") }
    #expect(store.evict() > 0)
    #expect(store.lookup("key7", mutation: mutation) != nil)
    #expect(store.lookup("key0", mutation: mutation) == nil)
}

@Test func `max-mutants leaves the rest untested, and a resumed run decides only those`() async throws {
    let base = try fixture(twoSites)
    defer { try? FileManager.default.removeItem(at: base) }
    let driver = try BuildDriver(root: base.path + "/input", scheme: nil, destination: nil)
    var limited = options()
    limited.maxMutants = 1
    let first = try await MutationRunner(executor: FakeExecutor()).run(
        driver: driver,
        outputDirectory: base.path + "/run1",
        options: limited
    )
    #expect(first.results.map(\.verdict) == [.killed, .notRun])
    #expect(first.budget?.stoppedBy == "max-mutants" && first.budget?.untested.count == 1)
    #expect(first.isSuccessfulExecution && first.score.percent == 100)
    let report = try await MutationReport.make(first, root: base.path + "/input")
    #expect(report.findings.allSatisfy { $0.severity == "note" })

    var resumed = options()
    resumed.resume = base.path + "/run1"
    let executor = FakeExecutor()
    let second = try await MutationRunner(executor: executor).run(
        driver: driver,
        outputDirectory: base.path + "/run2",
        options: resumed
    )
    #expect(second.results.map(\.verdict) == [.killed, .killed])
    #expect(second.results[0].reusedFrom == first.provenance.runID && second.results[1].reusedFrom == nil)
    #expect(second.reuse?.resumed == 1)
    #expect(
        executor.calls.withLock { $0.map { $0[ActivationEnvironment.activeID] ?? "" } }.filter { !$0.isEmpty }.count
            == 2
    )
}

@Test func `a time budget stops starting work and reports what did not run`() async throws {
    let executor = FakeExecutor(.init(buildDelay: .milliseconds(1_200)))
    let (result, base) = try await run(executor, source: twoSites) { $0.budgetSeconds = 1 }
    defer { try? FileManager.default.removeItem(at: base) }
    #expect(result.results.allSatisfy { $0.verdict == .notRun })
    #expect(result.budget?.stoppedBy == "time" && result.budget?.untested.count == 2)
    #expect(result.isSuccessfulExecution && result.score.percent == nil)
    // One build at most: under load the setup alone can spend the budget, and then nothing is built.
    #expect(executor.builds.withLock { $0 } <= 1)
}

// MARK: - Workspaces (ADR 0007)

@Test func `in place, originals are backed up before a rewrite and restored, also by a later start`() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("litmus-inplace-" + UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: root) }
    try FileManager.default.createDirectory(atPath: root + "/Sources", withIntermediateDirectories: true)
    let file = root + "/Sources/A.swift"
    let original = Array("let a = true\n".utf8)
    try Data(original).write(to: URL(fileURLWithPath: file))
    let journal = InPlaceJournal(root: root)
    try journal.rewrite(file, original: original, schema: Array("let a = schema\n".utf8))
    #expect(try String(contentsOfFile: file, encoding: .utf8) == "let a = schema\n")
    #expect(journal.outstanding.count == 1)
    // A crash here: a later start (a new journal) finds the record and restores the original.
    #expect(try InPlaceJournal(root: root).restoreAll() == 1)
    #expect(try Data(contentsOf: URL(fileURLWithPath: file)) == Data(original))
    #expect(journal.outstanding.isEmpty)

    // A crash after the record, before the rewrite: nothing to put back, the record goes.
    try journal.rewrite(file, original: original, schema: Array("x\n".utf8))
    try Data(original).write(to: URL(fileURLWithPath: file))
    #expect(try journal.restoreAll() == 0)
    #expect(journal.outstanding.isEmpty)

    // Edited meanwhile: left alone, its original kept, the run told.
    try journal.rewrite(file, original: original, schema: Array("schema\n".utf8))
    try Data("someone's edit\n".utf8).write(to: URL(fileURLWithPath: file))
    #expect(throws: LitmusFailure.self) { try journal.restoreAll() }
    #expect(try String(contentsOfFile: file, encoding: .utf8) == "someone's edit\n")
    #expect(journal.outstanding.count == 1)
    try Data("schema\n".utf8).write(to: URL(fileURLWithPath: file))
    #expect(try InPlaceRestore.restore(root: root) == 1)
    #expect(try Data(contentsOf: URL(fileURLWithPath: file)) == Data(original))
    #expect(!FileManager.default.fileExists(atPath: root + "/.litmus"))
}

@Test func `an in-place run decides the same verdicts and leaves the subject as it was`() async throws {
    let base = try fixture(twoSites)
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.path + "/input"
    let before = try Data(contentsOf: URL(fileURLWithPath: root + "/Sources/Example/F.swift"))
    let (result, _) = try await runIn(base) { $0.workspace = .inPlace }
    #expect(result.results.map(\.verdict) == [.killed, .killed] && result.isSuccessfulExecution)
    #expect(try Data(contentsOf: URL(fileURLWithPath: root + "/Sources/Example/F.swift")) == before)
    #expect(FileManager.default.fileExists(atPath: root + "/Package.swift"))
    #expect(!FileManager.default.fileExists(atPath: root + "/.litmus"))
    #expect(result.notes.contains { $0.hasPrefix("in place: 1 mutated file(s) restored and verified") })
}

@Test func `an in-place run that fails restores the subject before it reports`() async throws {
    let base = try fixture(twoSites)
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.path + "/input"
    let before = try Data(contentsOf: URL(fileURLWithPath: root + "/Sources/Example/F.swift"))
    await #expect(throws: (any Error).self) {
        try await MutationRunner(executor: FakeExecutor(.init(failsBaseline: true))).run(
            driver: try BuildDriver(root: root, scheme: nil, destination: nil),
            outputDirectory: base.path + "/run",
            options: {
                var o = options(); o.workspace = .inPlace; return o
            }()
        )
    }
    #expect(try Data(contentsOf: URL(fileURLWithPath: root + "/Sources/Example/F.swift")) == before)
    #expect(!FileManager.default.fileExists(atPath: root + "/.litmus"))
}

@Test func `a persistent workspace is synchronised by manifest, verified, and refused when not Litmus's`() async throws
{
    let base = try fixture(twoSites)
    defer { try? FileManager.default.removeItem(at: base) }
    let source = base.path + "/input", directory = base.path + "/persistent"
    try PersistentWorkspace.claim(directory, source: source)
    let (first, created) = try await PersistentWorkspace.synchronize(source: source, directory: directory)
    #expect(created == ["persistent workspace created"])
    let tree = directory + "/tree"
    // Build state survives; a leftover schema from an interrupted run, an extra file and a source change are repaired.
    try FileManager.default.createDirectory(atPath: tree + "/.build", withIntermediateDirectories: true)
    try Data("object".utf8).write(to: URL(fileURLWithPath: tree + "/.build/A.o"))
    let unchanged =
        try FileManager.default.attributesOfItem(atPath: tree + "/Package.swift")[.modificationDate] as? Date
    try Data("leftover schema".utf8).write(to: URL(fileURLWithPath: tree + "/Sources/Example/F.swift"))
    try FileManager.default.createDirectory(atPath: tree + "/Sources/Gone", withIntermediateDirectories: true)
    try Data("x".utf8).write(to: URL(fileURLWithPath: tree + "/Sources/Gone/G.swift"))
    try Data("let added = 1\n".utf8).write(to: URL(fileURLWithPath: source + "/Sources/Example/New.swift"))
    let (second, notes) = try await PersistentWorkspace.synchronize(source: source, directory: directory)
    #expect(notes == ["persistent workspace synchronised and verified: 1 changed, 1 added, 1 removed, 1 unchanged"])
    #expect(second.entries == (try await WorkspaceSnapshot.currentEntries(source)))
    #expect(second.entries != first.entries)
    #expect(FileManager.default.fileExists(atPath: tree + "/.build/A.o"))
    #expect(!FileManager.default.fileExists(atPath: tree + "/Sources/Gone"))
    #expect(
        (try FileManager.default.attributesOfItem(atPath: tree + "/Package.swift")[.modificationDate] as? Date)
            == unchanged
    )
    // Not a workspace: refused, nothing written.
    let foreign = base.path + "/foreign"
    try FileManager.default.createDirectory(atPath: foreign, withIntermediateDirectories: true)
    try Data("mine".utf8).write(to: URL(fileURLWithPath: foreign + "/notes.txt"))
    #expect(throws: LitmusFailure.self) { try PersistentWorkspace.claim(foreign, source: source) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: foreign) == ["notes.txt"])
    // One run per workspace.
    let lock = try WorkspaceLock(path: directory + "/lock")
    #expect(throws: LitmusFailure.self) { try WorkspaceLock(path: directory + "/lock") }
    lock.release()
}

@Test func `a persistent run keeps its workspace and the next run reuses it`() async throws {
    let base = try fixture(twoSites)
    defer { try? FileManager.default.removeItem(at: base) }
    let directory = base.path + "/persistent"
    let (first, _) = try await runIn(base, output: "run1") { $0.workspace = .persistent(directory) }
    let (second, _) = try await runIn(base, output: "run2") { $0.workspace = .persistent(directory) }
    #expect(first.results.map(\.verdict) == second.results.map(\.verdict))
    #expect(FileManager.default.fileExists(atPath: directory + "/tree/Package.swift"))
    #expect(second.notes.contains { $0.hasPrefix("persistent workspace synchronised and verified: 0 changed") })
    #expect(first.cost?.workspaceMiB == 0)
}

private func runIn(
    _ base: URL,
    output: String = "run",
    configure: (inout RunOptions) -> Void
) async throws -> (RunArtifact, FakeExecutor) {
    let executor = FakeExecutor()
    var options = options()
    configure(&options)
    let artifact = try await MutationRunner(executor: executor).run(
        driver: try BuildDriver(root: base.path + "/input", scheme: nil, destination: nil),
        outputDirectory: base.path + "/" + output,
        options: options
    )
    return (artifact, executor)
}

// MARK: - Gate and reports (ADR 0007)

@Test func `a baseline of anchored fingerprints gates only new survivors, and a change scopes the findings`()
    async throws
{
    let (artifact, base) = try await run(FakeExecutor(.init(active: .pass)), source: twoSites)
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.path + "/input"
    let all = try await MutationReport.make(artifact, root: root, relative: true)
    #expect(all.findings.count == 2 && all.findings.allSatisfy { $0.severity == "warning" })
    // The base branch held one of them: only the other is new.
    let held = try #require(all.findings.first?.anchoredFingerprint)
    let gated = try await MutationReport.make(artifact, root: root, relative: true, baseline: [held])
    #expect(gated.findings.count == 1 && gated.suppressed.count == 1)
    // A change touching line 2 only: the finding on line 1 is out of scope.
    let scope = ChangeScope(
        changed: ChangedLines(files: ["Sources/Example/F.swift": [2...2]]),
        breadth: .lines,
        source: "test",
        digest: "d"
    )
    let scoped = try await MutationReport.make(artifact, root: root, relative: true, change: scope)
    #expect(scoped.findings.map(\.line) == [2] && scoped.outOfScope.count == 1)
}

@Test func `Stryker's report schema and a Markdown summary are rendered from a run`() async throws {
    let (artifact, base) = try await run(FakeExecutor(), source: twoSites)
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.path + "/input"
    let json = try StrykerReport.render(artifact, root: root)
    let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    #expect(object["schemaVersion"] as? String == "2")
    let files = try #require(object["files"] as? [String: [String: Any]])
    let file = try #require(files["Sources/Example/F.swift"])
    #expect((file["source"] as? String)?.contains("public func a") == true)
    let mutants = try #require(file["mutants"] as? [[String: Any]])
    #expect(mutants.compactMap { $0["status"] as? String } == ["Killed", "Killed"])
    let location = try #require(mutants.first?["location"] as? [String: [String: Int]])
    #expect(location["start"]?["line"] == 1 && (location["end"]?["column"] ?? 0) > (location["start"]?["column"] ?? 0))

    let report = try await MutationReport.make(artifact, root: root, relative: true)
    let markdown = MarkdownReport.render(report, artifact: artifact)
    #expect(markdown.hasPrefix("## Litmus mutation testing"))
    #expect(markdown.contains("**Score 100 %**"))
    #expect(markdown.contains("Cost: "))
}

// MARK: - Sharding (ADR 0007)

@Test func `shards partition by module unit, deterministically and disjointly`() throws {
    func site(_ path: String, _ n: Int) -> Mutation {
        Mutation(
            id: String(repeating: "0", count: 15) + String(n, radix: 16),
            path: path,
            line: n,
            column: 1,
            operatorID: .negateCondition,
            start: n,
            end: n + 1,
            original: "a",
            replacement: "!(a)",
            sourceFingerprint: "f"
        )
    }
    #expect(Sharding.unit(of: "Pkg/Sources/Core/Deep/A.swift") == "Pkg/Sources/Core")
    #expect(Sharding.unit(of: "Sources/Core/A.swift") == "Sources/Core")
    #expect(Sharding.unit(of: "App/View.swift") == "App")
    let mutations =
        (0..<6).map { site("Sources/A/F\($0).swift", $0) } + (6..<9).map { site("Sources/B/G.swift", $0) }
        + (9..<11).map { site("Sources/C/H.swift", $0) }
    let shards = Sharding.partition(mutations, count: 2)
    #expect(shards == Sharding.partition(mutations.reversed(), count: 2))
    #expect(shards == [["Sources/A"], ["Sources/B", "Sources/C"]])
    #expect(Set(shards.flatMap { $0 }).count == 3)
    #expect(throws: LitmusFailure.self) { try ShardSelection(parsing: "3/2") }
    #expect(throws: LitmusFailure.self) { try ShardSelection(parsing: "1") }
}

@Test func `two shards merged decide what one run decides, and mismatched shards are refused`() async throws {
    let base = try fixture(twoSites)
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.path + "/input"
    try Data(
        "// swift-tools-version: 6.4\nimport PackageDescription\nlet package = Package(name: \"Example\", targets: [.target(name: \"Example\"), .target(name: \"Other\")])"
            .utf8
    ).write(to: URL(fileURLWithPath: root + "/Package.swift"))
    try FileManager.default.createDirectory(atPath: root + "/Sources/Other", withIntermediateDirectories: true)
    try Data("public func c(_ z: Bool) -> Int { z ? 5 : 6 }\n".utf8)
        .write(to: URL(fileURLWithPath: root + "/Sources/Other/G.swift"))
    let (whole, _) = try await runIn(base, output: "whole") { _ in }
    let (one, _) = try await runIn(base, output: "s1") { $0.shard = try? ShardSelection(index: 1, count: 2) }
    let (two, _) = try await runIn(base, output: "s2") { $0.shard = try? ShardSelection(index: 2, count: 2) }
    #expect(one.results.count + two.results.count == whole.results.count)
    #expect(Set(one.results.map(\.mutation.path)).isDisjoint(with: two.results.map(\.mutation.path)))
    let merged = try ShardMerge.merge(runDirectories: [base.path + "/s2", base.path + "/s1"], output: base.path + "/m")
    #expect(
        Set(merged.results.map { "\($0.mutation.id) \($0.verdict)" })
            == Set(whole.results.map { "\($0.mutation.id) \($0.verdict)" })
    )
    #expect(merged.isSuccessfulExecution && merged.shard == nil)
    #expect(try await MutationReport.make(merged, root: root).successfulExecution)
    #expect(throws: LitmusFailure.self) {
        try ShardMerge.merge(runDirectories: [base.path + "/s1"], output: base.path + "/m2")
    }
    #expect(throws: LitmusFailure.self) {
        try ShardMerge.merge(runDirectories: [base.path + "/s1", base.path + "/s1"], output: base.path + "/m3")
    }
    #expect(throws: LitmusFailure.self) {
        try ShardMerge.merge(runDirectories: [base.path + "/s1", base.path + "/whole"], output: base.path + "/m4")
    }
}

@Test func `a path that does not exist yet is spelled as it will be once it does`() throws {
    let parent = "/private/tmp/litmus-canonical-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: parent) }
    let future = canonicalNew(parent + "/run/workspace")
    try FileManager.default.createDirectory(atPath: parent + "/run/workspace", withIntermediateDirectories: true)
    #expect(future == SourcePath.canonical(parent + "/run/workspace"))
    #expect(!future.hasPrefix("/private/"))
}

@Test func `in place, a package depending on one outside the root is never reused`() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("litmus-outside-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.path + "/App"
    try FileManager.default.createDirectory(atPath: root + "/Sources/App", withIntermediateDirectories: true)
    try Data(
        "// swift-tools-version: 6.4\nimport PackageDescription\nlet package = Package(name: \"App\", dependencies: [.package(path: \"../Kit\")], targets: [.target(name: \"App\")])"
            .utf8
    ).write(to: URL(fileURLWithPath: root + "/Package.swift"))
    let source = "public func a(_ x: Bool) -> Int { x ? 1 : 2 }\n"
    try Data(source.utf8).write(to: URL(fileURLWithPath: root + "/Sources/App/A.swift"))
    let mutations = try MutationPlanner.mutations(in: source, path: "Sources/App/A.swift")
    func context(inPlace: Bool) throws -> ReuseContext {
        try ReuseContext(
            mode: .closure,
            root: root,
            entries: [SnapshotEntry(path: "Sources/App/A.swift", sha256: "1")],
            wholeSnapshot: "whole",
            mutations: mutations,
            closureKnown: true,
            inPlace: inPlace,
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
                selectTestTargets: true,
                background: false,
                excluded: []
            )
        )
    }
    let inPlace = try context(inPlace: true)
    #expect(inPlace.outsideRoot == ["Sources/App/A.swift"])
    #expect(inPlace.key(mutations[0]) != (try context(inPlace: true)).key(mutations[0]))
    // A copy cannot build ../Kit at all: its whole snapshot is what the key covers.
    #expect(try context(inPlace: false).key(mutations[0]) == (try context(inPlace: false)).key(mutations[0]))
}
