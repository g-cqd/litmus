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
@Test func `schema ranges cannot be stacked or duplicated`() throws {
    let source = "func f(a: Bool, b: Bool)->Bool { if a && b { return true }; return false }"
    let sites = try MutationPlanner.mutations(in: source, path: "F.swift")
    #expect(throws: (any Error).self) { try SchemaWriter.render(source, mutations: sites) }
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
