import Foundation
import Synchronization
import Testing

@testable import LitmusCore

private func fixture() throws -> URL {
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
    try Data("public func choice(_ value: Bool) -> Int { value ? 1 : 2 }".utf8)
        .write(to: root.appendingPathComponent("input/Sources/Example/F.swift"))
    return root
}

@Test func `snapshot edits cannot change original and traversal is rejected`() throws {
    let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
    let source = base.appendingPathComponent("input").path
    let snapshot = try WorkspaceSnapshot.create(source: source, destination: base.appendingPathComponent("copy").path)
    let path = try snapshot.path(for: "Sources/Example/F.swift")
    try Data("changed".utf8).write(to: URL(fileURLWithPath: path))
    #expect(try String(contentsOfFile: source + "/Sources/Example/F.swift", encoding: .utf8).contains("choice"))
    #expect(throws: (any Error).self) { try snapshot.path(for: "../input/Package.swift") }
    #expect(throws: (any Error).self) { try WorkspaceSnapshot.create(source: source, destination: source + "/inside") }
}

@Test func `snapshot refuses symlinks instead of following external inputs`() throws {
    let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createSymbolicLink(atPath: base.path + "/input/link", withDestinationPath: "/tmp")
    #expect(throws: (any Error).self) {
        try WorkspaceSnapshot.create(source: base.path + "/input", destination: base.path + "/copy")
    }
    #expect(!FileManager.default.fileExists(atPath: base.path + "/copy"))
}

private final class FakeExecutor: ProcessExecutor {
    let calls = Mutex<[[String: String]]>([])
    let failsBaseline: Bool
    let swiftTestingOnly: Bool
    init(failsBaseline: Bool = false, swiftTestingOnly: Bool = false) {
        self.failsBaseline = failsBaseline; self.swiftTestingOnly = swiftTestingOnly
    }
    func execute(_ command: ToolCommand, directory: String, environment: [String: String], timeout: Int) async throws
        -> ProcessOutput
    {
        if let index = command.arguments.firstIndex(of: "--xunit-output") {
            calls.withLock { $0.append(environment) }
            let isActive = !(environment["LITMUS_ACTIVE_ID"] ?? "").isEmpty
            let fail = isActive || failsBaseline
            let xml =
                "<testsuites><testsuite><testcase name=\"choice\">\(fail ? "<failure message=\"assertion\"/>" : "")</testcase></testsuite></testsuites>"
            let requested = command.arguments[index + 1]
            let report = swiftTestingOnly ? String(requested.dropLast(4)) + "-swift-testing.xml" : requested
            try Data(xml.utf8).write(to: URL(fileURLWithPath: report))
            return ProcessOutput(exitStatus: fail ? 1 : 0, stdout: [], stderr: [], truncated: false, timedOut: false)
        }
        return ProcessOutput(
            exitStatus: 0,
            stdout: Array("fake toolchain".utf8),
            stderr: [],
            truncated: false,
            timedOut: false
        )
    }
}

@Test(arguments: [false, true]) func `runner confirms a kill with an intervening inactive control`(
    swiftTestingOnly: Bool
) async throws {
    let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
    let executor = FakeExecutor(swiftTestingOnly: swiftTestingOnly)
    let driver = try BuildDriver(root: base.path + "/input", scheme: nil, destination: nil)
    let result = try await MutationRunner(executor: executor).run(driver: driver, outputDirectory: base.path + "/run")
    #expect(result.isSuccessfulExecution)
    #expect(result.results.map(\.verdict) == [.killed])
    let active = try #require(result.results.first?.mutation.id)
    #expect(executor.calls.withLock { $0.map { $0["LITMUS_ACTIVE_ID"] ?? "" } } == ["", "", active, "", active])
    #expect(!FileManager.default.fileExists(atPath: base.path + "/run/workspace"))
    #expect(try ArtifactCodec.read(RunArtifact.self, path: base.path + "/run/run.pb").results.first?.verdict == .killed)
}

@Test func `failed baseline preserves an incomplete checkpoint with no kills`() async throws {
    let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
    let driver = try BuildDriver(root: base.path + "/input", scheme: nil, destination: nil)
    await #expect(throws: (any Error).self) {
        try await MutationRunner(executor: FakeExecutor(failsBaseline: true)).run(
            driver: driver,
            outputDirectory: base.path + "/run"
        )
    }
    let checkpoint = try ArtifactCodec.read(RunArtifact.self, path: base.path + "/run/run.json")
    #expect(!checkpoint.complete)
    #expect(checkpoint.results.map(\.verdict) == [.notRun])
    #expect(!checkpoint.isSuccessfulExecution)
}
