import Foundation
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

@Test func `snapshot refuses symlinks instead of following external inputs`() async throws {
    let base = try fixture()
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createSymbolicLink(atPath: base.path + "/input/link", withDestinationPath: "/tmp")
    await #expect(throws: (any Error).self) {
        try await WorkspaceSnapshot.create(source: base.path + "/input", destination: base.path + "/copy")
    }
    #expect(!FileManager.default.fileExists(atPath: base.path + "/copy"))
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
    }
    let config: Config
    let calls = Mutex<[[String: String]]>([])
    let deadlines = Mutex<[Int]>([])
    let builds = Mutex(0)
    init(_ config: Config = Config()) { self.config = config }

    private func sources(_ directory: String) -> [String] {
        let enumerator = FileManager.default.enumerator(atPath: directory + "/Sources")
        return (enumerator?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".swift") }
            .map { directory + "/Sources/" + $0 }
    }

    func execute(_ command: ToolCommand, directory: String, environment: [String: String], timeout: Int) async throws
        -> ProcessOutput
    {
        if command.arguments.contains("--build-tests") {
            builds.withLock { $0 += 1 }
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
        case .crash: return ProcessOutput(exitStatus: 139, stdout: [], stderr: [], truncated: false, timedOut: false)
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

private func run(_ executor: FakeExecutor, source: String? = nil) async throws -> (RunArtifact, URL) {
    let base = try source.map(fixture) ?? fixture()
    let driver = try BuildDriver(root: base.path + "/input", scheme: nil, destination: nil)
    let artifact = try await MutationRunner(executor: executor).run(
        driver: driver,
        outputDirectory: base.path + "/run",
        options: options()
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
    #expect(executor.calls.withLock { $0.map { $0[ActivationEnvironment.activeID] ?? "" } } == ["", "", active])
    #expect(!FileManager.default.fileExists(atPath: base.path + "/run/workspace"))
    #expect(try ArtifactCodec.read(RunArtifact.self, path: base.path + "/run/run.pb").results.first?.verdict == .killed)
    let journal = try ResultJournal.read(path: base.path + "/run/results.journal")
    #expect(journal.results.map(\.verdict) == [.killed])
    #expect(!journal.truncated)
}

@Test func `a mutant the control never reached is no coverage, and is not run`() async throws {
    let executor = FakeExecutor(.init(reach: false))
    let (result, base) = try await run(executor)
    defer { try? FileManager.default.removeItem(at: base) }
    #expect(result.results.map(\.verdict) == [.noCoverage])
    #expect(executor.calls.withLock { $0.count } == 2)
    #expect(result.score.percent == 0)
}

@Test func `a failure without activation is rerun and never counts as a kill`() async throws {
    let executor = FakeExecutor(.init(markActive: false))
    let (result, base) = try await run(executor)
    defer { try? FileManager.default.removeItem(at: base) }
    #expect(result.results.map(\.verdict) == [.infrastructureError])
    #expect(executor.calls.withLock { $0.count } == 4)
    #expect(!result.isSuccessfulExecution)
}

@Test func `a repeated crash after activation is a crash kill`() async throws {
    let executor = FakeExecutor(.init(active: .crash))
    let (result, base) = try await run(executor)
    defer { try? FileManager.default.removeItem(at: base) }
    #expect(result.results.map(\.verdict) == [.crashed])
    #expect(result.score.percent == 100)
}

@Test func `a timeout is rerun alone with twice the derived deadline`() async throws {
    let executor = FakeExecutor(.init(active: .hang))
    let (result, base) = try await run(executor)
    defer { try? FileManager.default.removeItem(at: base) }
    #expect(result.results.map(\.verdict) == [.timeout])
    #expect(executor.deadlines.withLock { Array($0.suffix(2)) } == [3, 6])
    #expect(result.policy?.deadline == 3)
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
    #expect(executor.builds.withLock { $0 } == 4)
}

@Test func `without a diagnostic on the mutant, a failing build is not called unviable`() async throws {
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
