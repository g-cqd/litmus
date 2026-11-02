import Testing

@testable import LitmusCore

@Test func `a nonzero process exit without a test failure is never a kill`() {
    #expect(
        Verdict.classify(exitStatus: 65, tests: TestCounts(passed: 0, failed: 0, skipped: 0)) == .infrastructureError
    )
}
@Test func `a real test failure kills and a passing execution survives`() {
    #expect(Verdict.classify(exitStatus: 1, tests: TestCounts(passed: 2, failed: 1, skipped: 0)) == .killed)
    #expect(Verdict.classify(exitStatus: 0, tests: TestCounts(passed: 3, failed: 0, skipped: 0)) == .survived)
}
@Test func `zero tests and contradictory success are infrastructure errors`() {
    #expect(
        Verdict.classify(exitStatus: 0, tests: TestCounts(passed: 0, failed: 0, skipped: 5)) == .infrastructureError
    )
    #expect(
        Verdict.classify(exitStatus: 0, tests: TestCounts(passed: 1, failed: 1, skipped: 0)) == .infrastructureError
    )
}
@Test func `host packages and iOS packages use different build drivers`() throws {
    let host = try BuildDriver(root: "/work/pkg", scheme: nil, destination: nil)
    #expect(host.buildCommand(workspace: "/scratch", artifacts: "/artifacts").arguments.contains("--build-tests"))
    let ios = try BuildDriver(root: "/work/pkg", scheme: "Library", destination: "platform=iOS Simulator,id=ABC")
    let cmd = ios.buildCommand(workspace: "/scratch", artifacts: "/artifacts")
    #expect(cmd.arguments.contains("build-for-testing"))
    #expect(cmd.arguments.contains("Library"))
    #expect(!cmd.arguments.contains("-project"))
    #expect(throws: (any Error).self) { try BuildDriver(root: "/work/pkg", scheme: "Library", destination: nil) }
}
@Test func `wire artifacts round trip and reject a truncated payload`() throws {
    let data = Array("{\"sites\":[]}".utf8)
    let bytes = ArtifactWire.encode(data)
    #expect(try ArtifactWire.decode(bytes) == data)
    #expect(throws: (any Error).self) { try ArtifactWire.decode(Array(bytes.dropLast())) }
}

@Test func `coloured compiler diagnostics are attributed to the mutant on their line`() throws {
    let root = "/tmp/litmus-diagnostics"
    let line =
        "\u{1B}]8;;https://example.com\u{1B}\\\u{1B}[1m\(root)/Sources/F.swift:3:7: \u{1B}[1;31merror: \u{1B}[1;39mcannot convert\u{1B}[0;0m\n"
    let diagnostics = CompilerDiagnostics(
        ProcessOutput(exitStatus: 1, stdout: Array(line.utf8), stderr: [], truncated: false, timedOut: false),
        snapshotRoot: root
    )
    #expect(diagnostics.errors.map(\.line) == [3])
    #expect(diagnostics.errors.first?.message == "cannot convert")
    let schema = RenderedSchema(text: "", lines: ["aaaaaaaaaaaaaaaa": 3...3, "bbbbbbbbbbbbbbbb": 5...5])
    #expect(diagnostics.suspects(in: [root + "/Sources/F.swift": schema]) == ["aaaaaaaaaaaaaaaa"])
}

@Test func `the chosen SwiftPM build system reaches every SwiftPM invocation`() throws {
    var driver = try BuildDriver(root: "/work/pkg", scheme: nil, destination: nil)
    driver.swiftPMBuildSystem = "native"
    #expect(driver.buildCommand(workspace: "/w", artifacts: "/a").arguments.contains("native"))
    #expect(try driver.testCommand(workspace: "/w", artifacts: "/a", result: "/r.xml").arguments.contains("native"))
    #expect(
        driver.swiftPMArguments(workspace: "/w", artifacts: "/a") == [
            "--package-path", "/w", "--scratch-path", "/a/build", "--build-system", "native",
        ]
    )
}
