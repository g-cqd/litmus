internal import Foundation
#if canImport(FoundationXML)
internal import FoundationXML
#endif
internal import SourceCorpus

/// Parses structured execution evidence, never greps human build logs for a kill.
public enum TestEvidence {
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
        guard !bytes.contains(0), let text = String(bytes: bytes, encoding: .utf8) else { throw LitmusFailure("xUnit evidence must be UTF-8 without NUL bytes") }
        guard !text.contains("<!DOCTYPE"), !text.contains("<!ENTITY") else { throw LitmusFailure("XML entities and doctypes are not accepted") }
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
}

private final class XUnitReader: NSObject, XMLParserDelegate {
    var passed = 0, failed = 0, skipped = 0, depth = 0
    var inCase = false, caseFailed = false, caseSkipped = false, invalid = false
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        depth += 1
        if depth > 64 { invalid = true; parser.abortParsing(); return }
        switch name {
        case "testcase":
            if inCase { invalid = true }
            inCase = true; caseFailed = false; caseSkipped = false
        case "failure":
            if !inCase { invalid = true }; caseFailed = true
        case "error": invalid = true // Runner/process errors are not assertions.
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
