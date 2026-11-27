internal import Foundation

#if canImport(FoundationXML)
    internal import FoundationXML
#endif

struct XcodeSummary: Decodable {
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

struct XcodeTests: Decodable {
    let testNodes: [Node]
    struct Node: Decodable {
        let nodeType: String?
        let name: String?
        let result: String?
        let children: [Node]?
    }
}
