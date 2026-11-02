/// Structured test evidence, independent of the process exit code.
public struct TestCounts: Codable, Sendable, Equatable {
    public let passed: Int
    public let failed: Int
    public let skipped: Int
    public init(passed: Int, failed: Int, skipped: Int) {
        self.passed = passed; self.failed = failed; self.skipped = skipped
    }
}

/// Infrastructure failures, invalid mutants and timeouts never count as kills.
public enum Verdict: String, Codable, Sendable {
    case killed, survived, timeout, invalid, infrastructureError, notRun

    /// Classification requires actual executed tests; nonzero status alone proves nothing.
    public static func classify(exitStatus: Int32, tests: TestCounts) -> Self {
        guard tests.passed >= 0, tests.failed >= 0, tests.skipped >= 0,
            tests.passed <= 10_000_000, tests.failed <= 10_000_000, tests.skipped <= 10_000_000,
            tests.passed + tests.failed > 0
        else { return .infrastructureError }
        if exitStatus == 0 { return tests.failed == 0 ? .survived : .infrastructureError }
        return tests.failed > 0 ? .killed : .infrastructureError
    }
}

/// An executable and its argv; never interpreted by a shell.
public struct ToolCommand: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]
    public init(executable: String, arguments: [String]) { self.executable = executable; self.arguments = arguments }
}
