/// Structured test evidence, independent of the process exit code.
public struct TestCounts: Codable, Sendable, Equatable {
    public let passed: Int
    public let failed: Int
    public let skipped: Int
    public init(passed: Int, failed: Int, skipped: Int) {
        self.passed = passed
        self.failed = failed
        self.skipped = skipped
    }
    /// Every test the run reported, whatever its result.
    public var total: Int { passed + failed + skipped }
}

/// The outcome of one mutant. The score follows the Stryker definition, so it is comparable with other tools.
public enum Verdict: String, Codable, Sendable, CaseIterable {
    /// A test failed with the mutant active, after its code ran.
    case killed
    /// The test process crashed with the mutant active, after its code ran, twice.
    case crashed
    /// The suite did not finish with the mutant active, after its code ran, also when rerun alone with twice the time.
    case timeout
    /// Every test passed with the mutant active, after its code ran.
    case survived
    /// No test reached the mutated code.
    case noCoverage
    /// The mutant does not compile, alone; outside the score.
    case unviable
    /// The evidence cannot support a verdict (a broken control, a failure without activation, an unreadable report).
    case infrastructureError
    /// Not executed.
    case notRun

    /// Detected by the tests: the numerator of the score.
    public var isDetected: Bool { [.killed, .crashed, .timeout].contains(self) }
    /// A verdict a complete, trustworthy run may hold.
    public var isResolved: Bool { ![.infrastructureError, .notRun].contains(self) }

    /// Classification of a finished run from structured counts; a non-zero status alone proves nothing.
    public static func classify(exitStatus: Int32, tests: TestCounts) -> Self {
        guard tests.passed >= 0, tests.failed >= 0, tests.skipped >= 0,
            tests.passed <= 10_000_000, tests.failed <= 10_000_000, tests.skipped <= 10_000_000,
            tests.passed + tests.failed > 0
        else { return .infrastructureError }
        if exitStatus == 0 { return tests.failed == 0 ? .survived : .infrastructureError }
        return tests.failed > 0 ? .killed : .infrastructureError
    }
}

/// The mutation score: detected ÷ (detected + undetected), unviable mutants outside both sides.
public struct MutationScore: Codable, Sendable, Equatable {
    public let detected: Int
    public let undetected: Int
    public let unviable: Int
    /// Mutants without a resolved verdict; a score with any of them is not reported.
    public let unresolved: Int
    /// Percentage, or nil when nothing was detected or undetected, or when any verdict is unresolved.
    public let percent: Double?
    /// The score over covered mutants only (no-coverage mutants left out).
    public let coveredPercent: Double?

    public init(_ verdicts: [Verdict]) {
        detected = verdicts.count(where: \.isDetected)
        let survived = verdicts.count(where: { $0 == .survived })
        let uncovered = verdicts.count(where: { $0 == .noCoverage })
        undetected = survived + uncovered
        unviable = verdicts.count(where: { $0 == .unviable })
        let unresolved = verdicts.count(where: { !$0.isResolved })
        self.unresolved = unresolved
        func ratio(_ part: Int, _ whole: Int) -> Double? {
            whole > 0 && unresolved == 0 ? (Double(part) * 10_000 / Double(whole)).rounded() / 100 : nil
        }
        let detected = self.detected
        percent = ratio(detected, detected + survived + uncovered)
        coveredPercent = ratio(detected, detected + survived)
    }
}

/// An executable and its argv; never interpreted by a shell.
public struct ToolCommand: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]
    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}
