import Foundation
import Testing

@testable import LitmusCore

@Suite struct UISessionTests {
    /// `xcresulttool get test-results tests` of a three-configuration session on bench/Transit (trimmed to the fields read).
    static let session = #"""
        {"testNodes":[{"nodeType":"Test Plan","name":"litmus","result":"Failed","children":[{"nodeType":"UI test bundle","name":"TransitUITests","result":"Failed","children":[{"nodeType":"Test Suite","name":"TripUITests","result":"Failed","children":[{"nodeType":"Test Case","name":"testBuyingShowsThePayment()","result":"Failed","children":[{"nodeType":"Test Plan Configuration","name":"control","result":"Passed"},{"nodeType":"Test Plan Configuration","name":"m-6eb42e62f9e66c86","result":"Passed"},{"nodeType":"Test Plan Configuration","name":"m-048be6ec91776615","result":"Failed","children":[{"nodeType":"Failure Message","name":"XCTAssertTrue failed"}]}]}]}]}]}]}
        """#

    @Test func `a session's results are counted per test-plan configuration and test bundle`() throws {
        let results = try #require(XcodeConfigurations.counts(Array(Self.session.utf8)))
        #expect(results["control"] == ["TransitUITests": TestCounts(passed: 1, failed: 0, skipped: 0)])
        #expect(results["m-6eb42e62f9e66c86"] == ["TransitUITests": TestCounts(passed: 1, failed: 0, skipped: 0)])
        #expect(results["m-048be6ec91776615"] == ["TransitUITests": TestCounts(passed: 0, failed: 1, skipped: 0)])
    }

    @Test func `a single-configuration result tree is not read as a session`() {
        let single = #"""
            {"testNodes":[{"nodeType":"Unit test bundle","name":"T","result":"Passed","children":[{"nodeType":"Test Case","name":"a()","result":"Passed"}]}]}
            """#
        #expect(XcodeConfigurations.counts(Array(single.utf8)) == nil)
    }

    @Test func `format-1 targets become one named configuration each in a format-2 xctestrun`() throws {
        let format1: [String: Any] = [
            "__xctestrun_metadata__": ["FormatVersion": 1],
            "AppUITests": [
                "TestBundlePath": "x.xctest",
                "UITargetAppEnvironmentVariables": ["LITMUS_ACTIVE_ID_t": "a"],
            ],
        ]
        let targets = try #require(XcodeConfigurations.testTargets(format1))
        #expect(targets.count == 1)
        #expect(targets[0]["BlueprintName"] as? String == "AppUITests")
        let plist = XcodeConfigurations.plist([("litmus-a", targets), ("litmus-b", targets)])
        let configurations = try #require(plist["TestConfigurations"] as? [[String: Any]])
        #expect(configurations.map { $0["Name"] as? String } == ["litmus-a", "litmus-b"])
        #expect((plist["__xctestrun_metadata__"] as? [String: Int])?["FormatVersion"] == 2)
        _ = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    @Test func `xcodebuild runs keep sampling but drop the memory limit, which covers only xcodebuild's session`() {
        var base = Supervision()
        base.memoryLimitBytes = 4 << 30
        base.sampling = .milliseconds(100)
        let supervision = XcodeHarness<BoundedExecutor>.supervision(base)
        #expect(supervision.memoryLimitBytes == nil)
        #expect(supervision.sampling == .milliseconds(100))
    }
}
