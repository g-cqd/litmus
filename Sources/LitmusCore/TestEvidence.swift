internal import AemiJSON
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
        guard ["Passed", "Failed"].contains(summary.result),
            summary.totalTestCount >= 0, summary.totalTestCount <= 10_000_000,
            summary.passedTests >= 0, summary.failedTests >= 0, summary.skippedTests >= 0,
            summary.passedTests <= summary.totalTestCount, summary.failedTests <= summary.totalTestCount,
            summary.skippedTests <= summary.totalTestCount,
            summary.passedTests + summary.failedTests + summary.skippedTests == summary.totalTestCount,
            (summary.result == "Passed") == (summary.failedTests == 0)
        else { throw LitmusFailure("inconsistent or unsupported xcresult test summary") }
        return TestCounts(passed: summary.passedTests, failed: summary.failedTests, skipped: summary.skippedTests)
    }
}

private struct XcodeSummary: Decodable {
    let result: String
    let totalTestCount: Int
    let passedTests: Int
    let failedTests: Int
    let skippedTests: Int
    let testFailures: [Failure]?
    struct Failure: Decodable {
        let failureText: String?
        let targetName: String?
    }
}

extension TestEvidence {
    /// True when every failure of an `xcresulttool get test-results summary` reports a crash of the test runner or
    /// host ("The test runner crashed…", "Test crashed with signal…", "Crash: …"): a crash, not a failed test.
    public static func xcresultCrashed(_ bytes: [UInt8]) -> Bool {
        guard let summary = try? ArtifactCodec.decode(XcodeSummary.self, bytes: bytes),
            let failures = summary.testFailures, !failures.isEmpty
        else { return false }
        return failures.allSatisfy { failure in
            let text = (failure.failureText ?? "").lowercased()
            return text.contains("crashed") || text.hasPrefix("crash:")
        }
    }

    /// The test targets the failures of an `xcresulttool get test-results summary` name, in order without repeats:
    /// what `-skip-testing:` takes.
    public static func xcresultFailedTargets(_ bytes: [UInt8]) -> [String] {
        guard let summary = try? ArtifactCodec.decode(XcodeSummary.self, bytes: bytes) else { return [] }
        var seen: Set<String> = []
        return (summary.testFailures ?? []).compactMap(\.targetName).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Counts per test bundle from `xcresulttool get test-results tests`: each "Unit test bundle" (or UI test bundle)
    /// node's test cases by result. Nil when the shape is not understood.
    public static func xcresultModules(_ bytes: [UInt8]) -> [String: TestCounts]? {
        guard let tree = try? ArtifactCodec.decode(XcodeTests.self, bytes: bytes) else { return nil }
        var counts: [String: TestCounts] = [:]
        func cases(_ node: XcodeTests.Node, depth: Int, into total: inout (Int, Int, Int)) -> Bool {
            guard depth < 64 else { return false }
            if node.nodeType == "Test Case" {
                switch node.result {
                case "Passed", "Expected Failure": total.0 += 1
                case "Failed": total.1 += 1
                case "Skipped": total.2 += 1
                default: return false
                }
                return true
            }
            for child in node.children ?? [] where !cases(child, depth: depth + 1, into: &total) { return false }
            return true
        }
        func bundles(_ node: XcodeTests.Node, depth: Int) -> Bool {
            guard depth < 64 else { return false }
            if node.nodeType == "Unit test bundle" || node.nodeType == "UI test bundle" {
                var total = (0, 0, 0)
                guard let name = node.name, cases(node, depth: depth, into: &total) else { return false }
                let previous = counts[name] ?? TestCounts(passed: 0, failed: 0, skipped: 0)
                counts[name] = TestCounts(
                    passed: previous.passed + total.0,
                    failed: previous.failed + total.1,
                    skipped: previous.skipped + total.2
                )
                return true
            }
            for child in node.children ?? [] where !bundles(child, depth: depth + 1) { return false }
            return true
        }
        for node in tree.testNodes where !bundles(node, depth: 0) { return nil }
        return counts
    }
}

private struct XcodeTests: Decodable {
    let testNodes: [Node]
    struct Node: Decodable {
        let nodeType: String?
        let name: String?
        let result: String?
        let children: [Node]?
    }
}

private final class XUnitReader: NSObject, XMLParserDelegate {
    var passed = 0, failed = 0, skipped = 0, depth = 0
    var inCase = false, caseFailed = false, caseSkipped = false, invalid = false
    func parser(
        _ parser: XMLParser,
        didStartElement name: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        depth += 1
        if depth > 64 { invalid = true; parser.abortParsing(); return }
        switch name {
        case "testcase":
            if inCase { invalid = true }
            inCase = true; caseFailed = false; caseSkipped = false
        case "failure":
            if !inCase { invalid = true }; caseFailed = true
        case "error": invalid = true  // Runner/process errors are not assertions.
        case "skipped":
            if !inCase { invalid = true }; caseSkipped = true
        default: break
        }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "testcase" {
            if !inCase || caseFailed && caseSkipped { invalid = true }
            if caseFailed { failed += 1 } else if caseSkipped { skipped += 1 } else { passed += 1 }
            inCase = false
        }
        depth -= 1
    }
}
