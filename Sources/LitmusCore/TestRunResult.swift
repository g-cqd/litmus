internal import Foundation

/// What a suite execution showed, before activation is considered.
public enum TestRunOutcome: String, Codable, Sendable {
    case passed, failed, crashed, timedOut, unusable
}

/// The structured result of one suite execution.
public struct TestRunResult: Sendable {
    public let outcome: TestRunOutcome
    /// Complete counts; nil after a fail-fast stop or a crash.
    public let counts: TestCounts?
    public let nanoseconds: Int64
    /// Evidence files, relative to the run directory.
    public let evidence: [String]
    public let reason: String
    /// Swift Testing tests with a failing issue, identifiers without their source location; empty when unknown.
    public var failingTests: [String] = []
    /// Counts per test module, for a harness that runs modules separately; empty otherwise.
    public var moduleCounts: [String: TestCounts] = [:]
    /// The test module whose bundle ended the run, when it did not pass; nil when unknown.
    public var failedModule: String? = nil
    /// Per-test mutant reach collected during a single-pass control run (`collectPerTestReach`).
    public var perTestReach: [String: Set<String>] = [:]
    /// Mutants evaluated outside any test boundary during single-pass collection (`static let`, launch init).
    public var outsideTests: Set<String> = []
    /// Per-test execution durations in nanoseconds collected from the event stream.
    public var testDurations: [String: Int64] = [:]
    /// Per-test counts collected from the event stream.
    public var perTestCounts: [String: TestCounts] = [:]
    /// Decided inside a shared worker (no process start): its time must not shorten fresh processes' deadlines.
    public var ranInSharedWorker = false

    mutating func absorb(_ scan: TestEvidence.EventScan?) {
        guard let scan else { return }
        for (id, tests) in scan.perTestReach { perTestReach[id, default: []].formUnion(tests) }
        outsideTests.formUnion(scan.outsideTests)
        for (test, nanos) in scan.testDurations { testDurations[test] = max(testDurations[test] ?? 0, nanos) }
        perTestCounts.merge(scan.perTestCounts) { _, new in new }
    }
}
