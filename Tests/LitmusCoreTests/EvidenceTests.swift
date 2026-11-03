import Foundation
import Testing

@testable import LitmusCore

@Test func `xunit counts cases once under nested suites`() throws {
    let xml =
        "<testsuites><testsuite><testsuite><testcase/><testcase><failure/></testcase><testcase><skipped/></testcase></testsuite></testsuite></testsuites>"
    #expect(try TestEvidence.xunit(Array(xml.utf8)) == TestCounts(passed: 1, failed: 1, skipped: 1))
}
@Test(arguments: [
    "<testsuite><testcase>", "<!DOCTYPE x><testsuite/>", "<testsuite><testcase><error/></testcase></testsuite>",
    "<testcase><testcase/></testcase>",
])
func `malformed and infrastructure XML cannot be test evidence`(xml: String) throws {
    #expect(throws: (any Error).self) { try TestEvidence.xunit(Array(xml.utf8)) }
}
@Test func `xcresult requires consistent structured totals`() throws {
    let good = #"{"result":"Passed","passedTests":3,"failedTests":0,"skippedTests":1,"totalTestCount":4}"#
    #expect(try TestEvidence.xcresult(Array(good.utf8)) == TestCounts(passed: 3, failed: 0, skipped: 1))
    let bad = good.replacingOccurrences(of: "\"totalTestCount\":4", with: "\"totalTestCount\":5")
    #expect(throws: (any Error).self) { try TestEvidence.xcresult(Array(bad.utf8)) }
}
@Test func `wire rejects unknown versions duplicate payloads and corruption`() throws {
    let bytes = ArtifactWire.encode(Array("{}".utf8))
    var badVersion = bytes; badVersion[1] = 2
    #expect(throws: (any Error).self) { try ArtifactWire.decode(badVersion) }
    #expect(throws: (any Error).self) { try ArtifactWire.decode(bytes + bytes) }
    var corrupt = bytes; corrupt[5] ^= 1
    #expect(throws: (any Error).self) { try ArtifactWire.decode(corrupt) }
}
@Test func `same-range mutants chain in one replacement, duplicated mutants are refused`() throws {
    let source = "func f(a: Bool, b: Bool)->Bool { if a && b { return true }; return false }"
    let sites = try MutationPlanner.mutations(in: source, path: "F.swift")
    #expect(sites.count == 2)
    let rendered = try SchemaWriter.render(source, mutations: sites)
    #expect(rendered.contains("if (__litmus_"))
    let first = try #require(sites.first)
    #expect(throws: (any Error).self) { try SchemaWriter.render(source, mutations: [first, first]) }
}

@Test func `SwiftPM combines XCTest and Swift Testing reports without mistaking missing primary XML for zero tests`()
    throws
{
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("litmus-xml-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: base) }
    let requested = base.path + "/tests.xml"
    try Data("<testsuites><testsuite><testcase/><testcase><failure/></testcase></testsuite></testsuites>".utf8)
        .write(to: base.appendingPathComponent("tests-swift-testing.xml"))
    #expect(try TestEvidence.swiftPM(at: requested).counts == TestCounts(passed: 1, failed: 1, skipped: 0))
    try Data("<testsuite><testcase/></testsuite>".utf8).write(to: URL(fileURLWithPath: requested))
    #expect(try TestEvidence.swiftPM(at: requested).counts == TestCounts(passed: 2, failed: 1, skipped: 0))
}

@Test(arguments: [Int.max, -1, 10_000_001])
func `xcresult rejects hostile counters before arithmetic`(counter: Int) throws {
    let json =
        "{\"result\":\"Failed\",\"passedTests\":\(counter),\"failedTests\":\(counter),\"skippedTests\":0,\"totalTestCount\":1}"
    #expect(throws: (any Error).self) { try TestEvidence.xcresult(Array(json.utf8)) }
}

@Test func `the score follows the Stryker definition and refuses unresolved runs`() {
    let score = MutationScore([.killed, .crashed, .survived, .noCoverage, .unviable])
    #expect(score.detected == 2)
    #expect(score.undetected == 2)
    #expect(score.percent == 50)
    #expect(score.coveredPercent == 66.67)
    #expect(MutationScore([.killed, .infrastructureError]).percent == nil)
}

@Test func `the event stream reports a failing issue and keeps a partial line for the next scan`() throws {
    let known =
        #"{"kind":"event","payload":{"kind":"issueRecorded","issue":{"isKnown":true},"testID":"T.a()"},"version":0}"#
    let failing =
        #"{"kind":"event","payload":{"kind":"issueRecorded","issue":{"isKnown":false},"testID":"T.b()"},"version":0}"#
    let first = try TestEvidence.swiftTestingEvents(Array((known + "\n" + String(failing.prefix(20))).utf8))
    #expect(!first.failed)
    #expect(first.consumed == known.utf8.count + 1)
    let second = try TestEvidence.swiftTestingEvents(Array((failing + "\n").utf8))
    #expect(second.failed)
    #expect(second.failedTests == ["T.b()"])
}

@Test func `the journal survives a frame cut short and rejects a corrupt one`() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("litmus-journal-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.path + "/results.journal"
    let site = try #require(
        try MutationPlanner.mutations(in: "func f(a: Bool) -> Int { a ? 1 : 2 }", path: "F.swift").first
    )
    let journal = try ResultJournal(path: path)
    try journal.append(MutationResult(mutation: site, verdict: .killed, reason: "test"))
    try journal.append(MutationResult(mutation: site, verdict: .survived, reason: "test"))
    #expect(try ResultJournal.read(path: path).results.map(\.verdict) == [.killed, .survived])
    let handle = try #require(FileHandle(forWritingAtPath: path))
    try handle.seekToEnd()
    try handle.write(contentsOf: Data([0x90, 0x01, 0x08]))
    try handle.close()
    let cut = try ResultJournal.read(path: path)
    #expect(cut.truncated)
    #expect(cut.results.count == 2)
}

@Test func `direct bundles are matched to modules, and an unknown layout is refused`() throws {
    let bin = FileManager.default.temporaryDirectory.appendingPathComponent("litmus-bin-" + UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: bin) }
    try FileManager.default.createDirectory(
        atPath: bin + "/ExampleTests.xctest/Contents/MacOS",
        withIntermediateDirectories: true
    )
    FileManager.default.createFile(
        atPath: bin + "/ExampleTests.xctest/Contents/MacOS/ExampleTests",
        contents: Data(),
        attributes: [.posixPermissions: 0o755]
    )
    let listing = "ExampleTests.LegacyTests/testA\nExampleTests.LegacyTests/testB\nExampleTests.`works`()\n"
    let bundles = try #require(SwiftPMDirectHarness<BoundedExecutor>.bundles(listing: listing, binPath: bin))
    #expect(bundles.count == 1)
    #expect(bundles.first?.xcTestClasses == ["ExampleTests.LegacyTests"])
    #expect(bundles.first?.xcTestCount == 2)
    #expect(bundles.first?.swiftTestingCount == 1)
    #expect(SwiftPMDirectHarness<BoundedExecutor>.bundles(listing: "Other.`x`()\nMore.`y`()", binPath: bin) == nil)
}

@Test func `a test identifier loses its source location for --filter`() {
    #expect(testName("Mod.Suite/`works`()/File.swift:12:6") == "Mod.Suite/`works`()")
    #expect(testName("Mod.`plain`()") == "Mod.`plain`()")
}

@Test func `a filter pattern selects one test whether or not its identifier carries a location`() throws {
    let pattern = try Regex(filterPattern(for: "Mod.`drain`()"))
    #expect("Mod.`drain`()".contains(pattern))
    #expect("Mod.`drain`()/F.swift:3:2".contains(pattern))
    #expect(!"Mod.`drain`()x".contains(pattern))
    #expect(!"Other.Mod.`drain`()".contains(pattern))
}

@Test func `Swift Testing counts come from the event stream, functions only`() throws {
    let lines = [
        #"{"kind":"test","payload":{"kind":"suite","id":"M.S"}}"#,
        #"{"kind":"test","payload":{"kind":"function","id":"M.S/`a \"quoted\" name`()/F.swift:1:1"}}"#,
        #"{"kind":"test","payload":{"kind":"function","id":"M.S/`fails`()/F.swift:2:1"}}"#,
        #"{"kind":"test","payload":{"kind":"function","id":"M.S/`skipped`()/F.swift:3:1"}}"#,
        #"{"kind":"event","payload":{"kind":"testEnded","testID":"M.S/`a \"quoted\" name`()/F.swift:1:1"}}"#,
        #"{"kind":"event","payload":{"kind":"issueRecorded","testID":"M.S/`fails`()/F.swift:2:1","issue":{"isKnown":false}}}"#,
        #"{"kind":"event","payload":{"kind":"testEnded","testID":"M.S/`fails`()/F.swift:2:1"}}"#,
        #"{"kind":"event","payload":{"kind":"testSkipped","testID":"M.S/`skipped`()/F.swift:3:1"}}"#,
        #"{"kind":"event","payload":{"kind":"testEnded","testID":"M.S"}}"#,
        #"{"kind":"event","payload":{"kind":"runEnded"}}"#,
    ]
    let scan = try TestEvidence.swiftTestingEvents(Array((lines.joined(separator: "\n") + "\n").utf8))
    #expect(scan.ended)
    #expect(scan.counts == TestCounts(passed: 1, failed: 1, skipped: 1))
}

/// Xcode result bundles: counts per test bundle for `-only-testing`, and a crashed runner told from a
/// failed test. Shapes recorded from Xcode 27 on 2026-11-02.
@Test func `xcresult test trees give counts per bundle, and a crashed runner is a crash`() throws {
    let tree = """
        {"devices":[],"testNodes":[{"nodeType":"Test Plan","name":"Example","result":"Failed","children":[
          {"nodeType":"Unit test bundle","name":"ExampleTests","result":"Failed","children":[
            {"nodeType":"Test Case","name":"fails plainly","result":"Failed","children":[
              {"nodeType":"Failure Message","name":"Expectation failed"}]},
            {"nodeType":"Test Suite","name":"CrashTests","result":"Failed","children":[
              {"nodeType":"Test Case","name":"testCrash()","result":"Failed"}]},
            {"nodeType":"Test Case","name":"passes","result":"Passed"},
            {"nodeType":"Test Case","name":"skipped","result":"Skipped"}]},
          {"nodeType":"Unit test bundle","name":"Other Tests","result":"Passed","children":[
            {"nodeType":"Test Case","name":"a","result":"Passed"}]}]}]}
        """
    let modules = try #require(TestEvidence.xcresultModules(Array(tree.utf8)))
    #expect(modules["ExampleTests"] == TestCounts(passed: 1, failed: 2, skipped: 1))
    #expect(modules["Other Tests"] == TestCounts(passed: 1, failed: 0, skipped: 0))
    #expect(
        TestEvidence.xcresultModules(
            Array(
                #"{"testNodes":[{"nodeType":"Unit test bundle","name":"X","children":[{"nodeType":"Test Case","result":"Mystery"}]}]}"#
                    .utf8
            )
        ) == nil
    )

    let crashed = """
        {"result":"Failed","totalTestCount":12,"passedTests":11,"failedTests":1,"skippedTests":0,"testFailures":[
          {"failureText":"The test runner crashed while preparing to run tests: xctest at static xctest.main()",
           "targetName":"ExampleTests","testName":"testCrash()"}]}
        """
    let failed = """
        {"result":"Failed","totalTestCount":12,"passedTests":10,"failedTests":2,"skippedTests":0,"testFailures":[
          {"failureText":"Expectation failed: gated(true, false)","targetName":"ExampleTests"},
          {"failureText":"The test runner crashed while preparing to run tests","targetName":"ExampleTests"}]}
        """
    #expect(TestEvidence.xcresultCrashed(Array(crashed.utf8)))
    #expect(!TestEvidence.xcresultCrashed(Array(failed.utf8)))
    #expect(try TestEvidence.xcresult(Array(crashed.utf8)) == TestCounts(passed: 11, failed: 1, skipped: 0))
}

@Test func `xcodebuild test commands select test targets with -only-testing`() throws {
    let driver = try BuildDriver(root: "/r", scheme: "S", destination: "platform=macOS")
    let command = try driver.testCommand(
        workspace: "/r",
        artifacts: "/a",
        result: "/x.xcresult",
        xctestrun: "/t.xctestrun",
        onlyTesting: ["B Tests", "ATests"]
    )
    #expect(Array(command.arguments.suffix(2)) == ["-only-testing:ATests", "-only-testing:B Tests"])
}

/// The simulator helper's harness: which destinations and bundles it takes, and what it tells the helper.
@Test func `the simulator harness takes hostless bundles on a simulator id, and xcodebuild keeps the rest`() throws {
    #expect(
        SimulatorDirectHarness<BoundedExecutor>.simulatorID(
            "platform=iOS Simulator,id=D9A33F74-0A25-4234-8FA9-5DC935E916BF"
        )
            == "D9A33F74-0A25-4234-8FA9-5DC935E916BF"
    )
    #expect(SimulatorDirectHarness<BoundedExecutor>.simulatorID("platform=iOS Simulator,name=iPhone 17") == nil)
    #expect(SimulatorDirectHarness<BoundedExecutor>.simulatorID("platform=macOS") == nil)

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "litmus-xctestrun-" + UUID().uuidString
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let plist: [String: Any] = [
        "__xctestrun_metadata__": ["FormatVersion": 2],
        "TestConfigurations": [
            [
                "TestTargets": [
                    [
                        "BlueprintName": "PackageTests",
                        "TestBundlePath": "__TESTROOT__/Debug-iphonesimulator/PackageTests.xctest",
                        "TestHostPath": "__PLATFORMS__/iPhoneSimulator.platform/Developer/Library/Xcode/Agents/xctest",
                        "EnvironmentVariables": ["FIXTURES": "__TESTROOT__/fixtures"],
                    ],
                    [
                        "BlueprintName": "AppTests",
                        "TestBundlePath": "__TESTROOT__/Debug-iphonesimulator/App.app/PlugIns/AppTests.xctest",
                        "TestHostPath": "__TESTROOT__/Debug-iphonesimulator/App.app",
                    ],
                ]
            ]
        ],
    ]
    let path = directory.appendingPathComponent("x.xctestrun").path
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(
        to: URL(fileURLWithPath: path)
    )
    let targets = try XCTestRunTarget.targets(xctestrun: path, products: "/P", platforms: "/X/Platforms")
    #expect(targets.map(\.name) == ["AppTests", "PackageTests"])
    #expect(targets.map(\.isHostless) == [false, true])
    #expect(targets[1].environment["FIXTURES"] == "/P/fixtures")
    #expect(SimulatorDirectHarness<BoundedExecutor>.bundles(targets) == nil)
    let bundles = try #require(SimulatorDirectHarness<BoundedExecutor>.bundles([targets[1]]))
    #expect(bundles.first?.binary == "/P/Debug-iphonesimulator/PackageTests.xctest/PackageTests")

    var request = TestRunRequest(
        name: "r",
        activeID: "",
        coverageDirectory: "/c",
        temporaryDirectory: "/t",
        deadline: 5,
        failFast: false
    )
    request.onlySwiftTesting = ["PackageTests.`a test`()"]
    request.repetitions = 3
    let configuration = SimulatorDirectHarness<BoundedExecutor>.configuration(request)
    let object = try #require(try JSONSerialization.jsonObject(with: Data(configuration.utf8)) as? [String: Any])
    #expect(object["repetitions"] as? Int == 3 && object["xctest"] as? Bool == false)
    #expect((object["filter"] as? [String])?.count == 1)

    let xctest = directory.appendingPathComponent("e.xctest").path
    try Data(
        #"{"xctest":{"name":"-[A b]","status":"passed"}}\#n{"xctest":{"name":"-[A c]","status":"failed"}}\#n"#.utf8
    )
    .write(to: URL(fileURLWithPath: xctest))
    #expect(
        SimulatorDirectHarness<BoundedExecutor>.xctestCounts(xctest) == TestCounts(passed: 1, failed: 1, skipped: 0)
    )
}

@Test func `a timed out simulator run names the XCTest case that never finished`() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("litmus-xctest-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("e.xctest").path
    try Data(
        """
        {"xctest":{"name":"-[A b]","status":"started"}}
        {"xctest":{"name":"-[A b]","status":"passed"}}
        {"xctest":{"name":"-[A c]","status":"started"}}

        """.utf8
    )
    .write(to: URL(fileURLWithPath: path))

    // Started lines are not results: the counts stay those of the finished cases.
    #expect(SimulatorDirectHarness<BoundedExecutor>.xctestCounts(path) == TestCounts(passed: 1, failed: 0, skipped: 0))
    #expect(SimulatorDirectHarness<BoundedExecutor>.unfinishedXCTests(path) == ["-[A c]"])
    #expect(SimulatorDirectHarness<BoundedExecutor>.unfinishedXCTests(path + ".missing").isEmpty)
    #expect(
        SimulatorDirectHarness<BoundedExecutor>.timeoutReason(
            deadline: 120,
            swiftTestingEnded: true,
            unfinished: ["-[A c]"]
        ) == "the simulator run exceeded 120 s; Swift Testing had finished, XCTest case -[A c] had not"
    )
    #expect(
        SimulatorDirectHarness<BoundedExecutor>.timeoutReason(deadline: 120, swiftTestingEnded: true, unfinished: [])
            == "the simulator run exceeded 120 s; every test had finished but the test process did not exit"
    )
    #expect(
        SimulatorDirectHarness<BoundedExecutor>.timeoutReason(deadline: 120, swiftTestingEnded: false, unfinished: [])
            == "the simulator run exceeded 120 s"
    )
}
