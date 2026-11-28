internal import AemiJSON
internal import AemiJSONCore
internal import Foundation
internal import SourceCorpus

#if canImport(FoundationXML)
    internal import FoundationXML
#endif

/// Parses structured execution evidence, never greps human build logs for a kill.
public enum TestEvidence {
    /// What a Swift Testing event stream (JSON Lines, version 0) says so far.
    public struct EventScan: Sendable, Equatable {
        /// Identifiers of tests with a recorded issue that is neither known nor a warning.
        public let failedTests: Set<String>
        /// Whether an issue failed the run, inside a test or not.
        public let failed: Bool
        /// Whether the stream reached `runEnded`.
        public let ended: Bool
        /// Bytes consumed: complete lines only, so a partially written line is read on the next scan.
        public let consumed: Int
        /// Test functions (not suites) that ended, and those of them with a failing issue; skipped functions.
        public var endedTests: Set<String> = []
        public var skippedTests: Set<String> = []
        /// Identifiers the stream declares as test functions (`test` records of kind `function`); empty when it
        /// declares none, and suites are then told apart by their identifiers (a function's holds `(`).
        public var functions: Set<String> = []
        /// Per-test mutant reach collected when `{"litmusReach":"<id>"}` lines are interleaved into a serial
        /// (`parallelizationWidth == 1`) event stream via a FIFO.
        public var perTestReach: [String: Set<String>] = [:]
        /// Mutants evaluated outside any active test function (launch, suite init, `static let` before a test starts,
        /// or evaluated multiple times vs once): any mutant in `outsideTests` or evaluated only once across multiple
        /// tests may depend on process-lifetime caching (`static let` / `lazy`).
        public var outsideTests: Set<String> = []
        /// Duration of each test function in nanoseconds, from `testStarted` to `testEnded` instants.
        public var testDurations: [String: Int64] = [:]
        /// Counts per individual test function (`passed: 1` or `skipped: 1`).
        public var perTestCounts: [String: TestCounts] = [:]

        /// The counts of test functions, from the stream alone: what xUnit would say, without its XML (which the
        /// toolchain writes unescaped when a test's name holds a double quote).
        public var counts: TestCounts {
            func isFunction(_ id: String) -> Bool { functions.isEmpty ? id.contains("(") : functions.contains(id) }
            let ended = endedTests.filter(isFunction)
            let failedEnded = ended.filter { failedTests.contains($0) }
            return TestCounts(
                passed: ended.count - failedEnded.count,
                failed: failedEnded.count,
                skipped: skippedTests.filter(isFunction).count
            )
        }
    }

    /// Scans the complete lines of a Swift Testing event stream with AemiJSON's lazy tape: only the touched keys are
    /// materialised. A malformed complete line is rejected, never skipped.
    /// - Complexity: O(*n*) in `bytes`.
    public static func swiftTestingEvents(_ bytes: [UInt8]) throws -> EventScan {
        var failedTests: Set<String> = [], endedTests: Set<String> = [], skippedTests: Set<String> = []
        var functions: Set<String> = []
        var perTestReach: [String: Set<String>] = [:]
        var outsideTests: Set<String> = []
        var activeFunctions: [String] = []
        var startInstants: [String: Double] = [:]
        var testDurations: [String: Int64] = [:]
        var failed = false, ended = false, start = 0, consumed = 0
        var index = 0
        func isFunction(_ id: String) -> Bool { functions.isEmpty ? id.contains("(") : functions.contains(id) }
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "\n") {
                if index > start {
                    let document = try AemiJSON.parse(Array(bytes[start..<index]))
                    let root = document.root
                    if let reachID = root.litmusReach.string, reachID.count == 16, reachID.allSatisfy(\.isHexDigit) {
                        if let current = activeFunctions.last {
                            perTestReach[reachID, default: []].insert(testName(current))
                        } else {
                            outsideTests.insert(reachID)
                        }
                    } else if root.kind.string == "event" {
                        let payload = root.payload
                        switch payload.kind.string {
                        case "issueRecorded":
                            let issue = payload.issue
                            let isWarning = issue.severity.string == "warning"
                            if issue.isKnown.bool != true, !isWarning {
                                failed = true
                                if let test = payload.testID.string { failedTests.insert(test) }
                            }
                        case "runEnded": ended = true
                        case "testStarted":
                            if let test = payload.testID.string, isFunction(test) {
                                activeFunctions.append(test)
                                if let instant = payload.instant.absolute.double { startInstants[test] = instant }
                            }
                        case "testEnded":
                            if let test = payload.testID.string {
                                endedTests.insert(test)
                                activeFunctions.removeAll { $0 == test }
                                if let endInstant = payload.instant.absolute.double, let begun = startInstants[test] {
                                    let nanos = Int64(max(0, endInstant - begun) * 1_000_000_000)
                                    let short = testName(test)
                                    testDurations[short] = max(testDurations[short] ?? 0, nanos)
                                }
                            }
                        case "testSkipped":
                            if let test = payload.testID.string {
                                skippedTests.insert(test)
                                activeFunctions.removeAll { $0 == test }
                            }
                        default: break
                        }
                    } else if root.kind.string == "test", root.payload.kind.string == "function",
                        let id = root.payload.id.string
                    {
                        functions.insert(id)
                    }
                }
                start = index + 1
                consumed = start
            }
            index += 1
        }
        var perTestCounts: [String: TestCounts] = [:]
        for id in endedTests where isFunction(id) {
            let short = testName(id)
            let prev = perTestCounts[short] ?? TestCounts(passed: 0, failed: 0, skipped: 0)
            if failedTests.contains(id) {
                perTestCounts[short] = TestCounts(passed: prev.passed, failed: prev.failed + 1, skipped: prev.skipped)
            } else {
                perTestCounts[short] = TestCounts(passed: prev.passed + 1, failed: prev.failed, skipped: prev.skipped)
            }
        }
        for id in skippedTests where isFunction(id) {
            let short = testName(id)
            let prev = perTestCounts[short] ?? TestCounts(passed: 0, failed: 0, skipped: 0)
            perTestCounts[short] = TestCounts(passed: prev.passed, failed: prev.failed, skipped: prev.skipped + 1)
        }
        var scan = EventScan(failedTests: failedTests, failed: failed, ended: ended, consumed: consumed)
        scan.endedTests = endedTests
        scan.skippedTests = skippedTests
        scan.functions = functions
        scan.perTestReach = perTestReach
        scan.outsideTests = outsideTests
        scan.testDurations = testDurations
        scan.perTestCounts = perTestCounts
        return scan
    }

    /// SwiftPM emits XCTest at the requested path (with --parallel) and Swift Testing at a suffixed path.
    /// Frameworks with no discovered tests may emit no file; at least one report is required.
    public static func swiftPM(at path: String) throws -> (counts: TestCounts, paths: [String]) {
        let swiftTesting = String(path.dropLast(4)) + "-swift-testing.xml"
        let paths = [path, swiftTesting].filter { FileManager.default.fileExists(atPath: $0) }
        guard !paths.isEmpty else { throw LitmusFailure("no structured XCTest or Swift Testing result was produced") }
        var passed = 0, failed = 0, skipped = 0
        for path in paths {
            let counts = try xunit(BoundedFileReader.read(path: path, cap: 16 << 20))
            passed += counts.passed; failed += counts.failed; skipped += counts.skipped
        }
        return (TestCounts(passed: passed, failed: failed, skipped: skipped), paths)
    }

    /// xUnit testcase elements are counted, not aggregate testsuite attributes (which may nest).
    public static func xunit(_ bytes: [UInt8]) throws -> TestCounts {
        guard bytes.count <= 16 << 20 else { throw LitmusFailure("test report exceeds 16 MiB") }
        guard !bytes.contains(0), let text = String(bytes: bytes, encoding: .utf8) else {
            throw LitmusFailure("xUnit evidence must be UTF-8 without NUL bytes")
        }
        guard !text.contains("<!DOCTYPE"), !text.contains("<!ENTITY") else {
            throw LitmusFailure("XML entities and doctypes are not accepted")
        }
        let delegate = XUnitReader()
        let parser = XMLParser(data: Data(bytes))
        parser.shouldResolveExternalEntities = false
        // SAFETY: XMLParser's imported delegate is unowned(unsafe). Keep its owner alive
        // throughout synchronous parsing and clear the pointer before leaving this scope.
        let parsed = withExtendedLifetime(delegate) {
            unsafe parser.delegate = delegate
            defer { unsafe parser.delegate = nil }
            return parser.parse()
        }
        guard parsed, !delegate.invalid, delegate.depth == 0 else { throw LitmusFailure("malformed xUnit evidence") }
        return TestCounts(passed: delegate.passed, failed: delegate.failed, skipped: delegate.skipped)
    }

    /// Xcode 16+ `xcresulttool get test-results summary`; unsupported summaries fail closed.
    public static func xcresult(_ bytes: [UInt8]) throws -> TestCounts {
        let summary = try ArtifactCodec.decode(XcodeSummary.self, bytes: bytes)
        // An expected failure is a test that behaved as declared: it counts as passed, as in the per-bundle counts.
        let expected = summary.expectedFailures ?? 0
        let total = summary.totalTestCount
        // Every counter is bounded before any is added: hostile values cannot overflow.
        guard ["Passed", "Failed"].contains(summary.result), total >= 0, total <= 10_000_000,
            (0...total).contains(summary.passedTests), (0...total).contains(summary.failedTests),
            (0...total).contains(summary.skippedTests), (0...total).contains(expected)
        else { throw LitmusFailure("inconsistent or unsupported xcresult test summary") }
        let passed = summary.passedTests + expected
        guard passed + summary.failedTests + summary.skippedTests == total,
            (summary.result == "Passed") == (summary.failedTests == 0)
        else { throw LitmusFailure("inconsistent or unsupported xcresult test summary") }
        return TestCounts(passed: passed, failed: summary.failedTests, skipped: summary.skippedTests)
    }
}
