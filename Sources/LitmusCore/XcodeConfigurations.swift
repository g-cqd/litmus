internal import Foundation

/// The results of a multi-configuration `.xctestrun` session, per test-plan configuration.
enum XcodeConfigurations {
    /// Counts per test bundle for each configuration, from `xcresulttool get test-results tests`: each test case holds
    /// one "Test Plan Configuration" child per configuration it ran in. Nil when the tree has another shape.
    static func counts(_ bytes: [UInt8]) -> [String: [String: TestCounts]]? {
        guard let tree = try? ArtifactCodec.decode(XcodeTests.self, bytes: bytes) else { return nil }
        var result: [String: [String: TestCounts]] = [:]
        func add(_ configuration: String, _ bundle: String, _ outcome: String?) -> Bool {
            let old = result[configuration]?[bundle] ?? TestCounts(passed: 0, failed: 0, skipped: 0)
            let new: TestCounts
            switch outcome {
            case "Passed", "Expected Failure":
                new = TestCounts(passed: old.passed + 1, failed: old.failed, skipped: old.skipped)
            case "Failed": new = TestCounts(passed: old.passed, failed: old.failed + 1, skipped: old.skipped)
            case "Skipped": new = TestCounts(passed: old.passed, failed: old.failed, skipped: old.skipped + 1)
            default: return false
            }
            result[configuration, default: [:]][bundle] = new
            return true
        }
        func visit(_ node: XcodeTests.Node, bundle: String?, depth: Int) -> Bool {
            guard depth < 64 else { return false }
            var bundle = bundle
            if node.nodeType == "Unit test bundle" || node.nodeType == "UI test bundle" { bundle = node.name }
            if node.nodeType == "Test Case" {
                let runs = (node.children ?? []).filter { $0.nodeType == "Test Plan Configuration" }
                guard let bundle, !runs.isEmpty else { return false }
                return runs.allSatisfy { run in run.name.map { add($0, bundle, run.result) } ?? false }
            }
            return (node.children ?? []).allSatisfy { visit($0, bundle: bundle, depth: depth + 1) }
        }
        return tree.testNodes.allSatisfy { visit($0, bundle: nil, depth: 0) } ? result : nil
    }

    /// The test targets of a patched `.xctestrun` plist (format 1 or 2), each named, for a format-2 configuration.
    static func testTargets(_ plist: Any) -> [[String: Any]]? {
        guard let root = plist as? [String: Any] else { return nil }
        if let configurations = root["TestConfigurations"] as? [[String: Any]] {
            guard configurations.count == 1 else { return nil }
            return configurations[0]["TestTargets"] as? [[String: Any]]
        }
        var targets: [[String: Any]] = []
        for (name, value) in root.sorted(by: { $0.key < $1.key }) where name != "__xctestrun_metadata__" {
            guard var target = value as? [String: Any] else { return nil }
            target["BlueprintName"] = target["BlueprintName"] ?? name
            targets.append(target)
        }
        return targets
    }

    /// A format-2 `.xctestrun` with one configuration per `(name, targets)`, run in order in one session.
    static func plist(_ configurations: [(name: String, targets: [[String: Any]])]) -> [String: Any] {
        [
            "__xctestrun_metadata__": ["FormatVersion": 2],
            "TestPlan": ["Name": "litmus", "IsDefault": true],
            "TestConfigurations": configurations.map { ["Name": $0.name, "TestTargets": $0.targets] },
        ]
    }
}
