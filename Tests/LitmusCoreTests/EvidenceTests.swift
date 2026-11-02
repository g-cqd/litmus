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
