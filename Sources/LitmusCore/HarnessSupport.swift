internal import Foundation

/// A Swift Testing test identifier without its trailing source location (`/File.swift:12:6`), the form `--filter` takes.
func testName(_ identifier: String) -> String {
    guard let slash = identifier.lastIndex(of: "/"), identifier[slash...].contains(".swift:") else { return identifier }
    return String(identifier[..<slash])
}

/// The `--filter` pattern selecting exactly one test: Swift Testing matches it against identifiers that may still
/// carry `/File.swift:line:column`, so the pattern ends at a `/` or at the end, never at `$` alone (that matches
/// nothing: exit 69, probed 2026-11-02).
func filterPattern(for test: String) -> String {
    "^" + NSRegularExpression.escapedPattern(for: test) + "(/|$)"
}

/// Nanoseconds elapsed since `start` on the continuous clock.
func nanoseconds(since start: ContinuousClock.Instant) -> Int64 {
    let duration = ContinuousClock.now - start
    return duration.components.seconds * 1_000_000_000 + duration.components.attoseconds / 1_000_000_000
}

/// The common environment of every subject process: the selector, the marker directory, a private `TMPDIR`, and the
/// developer directory analyzerkit's scrubbing would drop.
func subjectEnvironment(_ request: TestRunRequest?) -> [String: String] {
    let token = request?.environmentToken ?? ""
    var environment = [ActivationEnvironment.key(ActivationEnvironment.activeID, token: token): request?.activeID ?? ""]
    if let request {
        environment[ActivationEnvironment.key(ActivationEnvironment.coverageDirectory, token: token)] =
            request.coverageDirectory
        environment["TMPDIR"] = request.temporaryDirectory
        // Unique per test run; also written into `.xctestrun` environments, so simulator processes carry it.
        environment[processTokenVariable] = request.coverageDirectory
    }
    if let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] { environment["DEVELOPER_DIR"] = developer }
    return environment
}

func writeLog(_ result: ProcessOutput, path: String) throws {
    let header = "exit=\(result.exitStatus) timeout=\(result.timedOut) truncated=\(result.truncated)\n--- stdout ---\n"
    let bytes = Array(header.utf8) + result.stdout + Array("\n--- stderr ---\n".utf8) + result.stderr
    try Data(bytes).write(to: URL(fileURLWithPath: path), options: .atomic)
}

/// The stop reason of a run stopped at its first failing Swift Testing issue.
let failFastReason = "Swift Testing recorded a failing issue"

/// The stop reason of an `xcodebuild` run whose simulator test host crashed and restarted mid-suite.
let hostCrashReason = "Xcode test host crashed and restarted"

/// The reason a process that ended without a structured result gives: its signal, the memory limit, or its status.
func abnormalEnd(_ output: ProcessOutput, _ name: String) -> String {
    if output.exceededMemory { return "\(name) exceeded the memory limit (\(output.stopReason ?? ""))" }
    if let signal = output.terminationSignal { return "\(name) was terminated by signal \(signal)" }
    return "\(name) exited \(output.exitStatus) without a recorded failure"
}
