import Foundation
import Testing

@testable import LitmusCore

private func finished(_ test: String, _ status: String) -> String {
    #"{"_type":{"_name":"StreamedEvent"},"name":{"_type":{"_name":"String"},"_value":"testFinished"},"structuredPayload":{"test":{"identifier":{"_type":{"_name":"String"},"_value":"\#(test)"},"testStatus":{"_type":{"_name":"String"},"_value":"\#(status)"}}}}"#
}

@Test func `the result stream shows a failed test and leaves a partial line for the next scan`() {
    let started = #"{"name":{"_value":"testStarted"}}"#
    let text = [started, finished("a()", "Success"), finished("b()", "Failure"), finished("c()", "Failure")].joined(
        separator: "\n"
    )
    let whole = XcodeResultStream.scan(Array((text + "\n").utf8))
    #expect(whole.failed && whole.failedTests == ["b()", "c()"])
    #expect(whole.consumed == (text + "\n").utf8.count)
    let cut = XcodeResultStream.scan(Array(text.utf8))
    #expect(cut.failedTests == ["b()"], "the last line has no newline yet, so it is not read")
    #expect(cut.consumed == (text.utf8.count - finished("c()", "Failure").utf8.count))
    #expect(!XcodeResultStream.scan(Array((finished("a()", "Success") + "\nnot json\n").utf8)).failed)
    #expect(!XcodeResultStream.scan([]).failed)
}

@Test func `a stream line of another shape is skipped, not misread`() {
    let odd = #"{"name":{"_value":"testFinished"},"x":"testStatus Failure"}"#
    #expect(!XcodeResultStream.scan(Array((odd + "\n").utf8)).failed)
}

@Test func `an Xcode test command names its worker's device, derived data and stream`() throws {
    let driver = try BuildDriver(
        root: "/repo",
        scheme: "App",
        destination: "platform=iOS Simulator,id=BASE"
    )
    let plain = try driver.testCommand(workspace: "/w", artifacts: "/a", result: "/r", xctestrun: "/x.xctestrun")
    #expect(plain.arguments.contains("-collect-test-diagnostics"))
    #expect(plain.arguments.contains("platform=iOS Simulator,id=BASE"))
    #expect(plain.arguments.contains("/a/DerivedData"))
    #expect(!plain.arguments.contains("-resultStreamPath"))
    let worker = try driver.testCommand(
        workspace: "/w",
        artifacts: "/a",
        result: "/r",
        xctestrun: "/x.xctestrun",
        resultStream: "/logs/s.jsonl",
        destination: "platform=iOS Simulator,id=WORKER",
        derivedData: "/a/workers/simulator-2/DerivedData"
    )
    let arguments = worker.arguments
    #expect(
        arguments.contains("platform=iOS Simulator,id=WORKER") && !arguments.contains("platform=iOS Simulator,id=BASE")
    )
    #expect(arguments.contains("/a/workers/simulator-2/DerivedData") && !arguments.contains("/a/DerivedData"))
    let stream = try #require(arguments.firstIndex(of: "-resultStreamPath"))
    #expect(arguments[stream + 1] == "/logs/s.jsonl")
}

@Test func `a simulator build pins the architecture unless the user chose one`() throws {
    let simulator = BuildDriver.simulatorArchitectureSettings(for: [], destination: "platform=iOS Simulator,id=X")
    #expect(simulator.count == 2 && simulator.contains("ONLY_ACTIVE_ARCH=YES") && simulator[0].hasPrefix("ARCHS="))
    #expect(BuildDriver.simulatorArchitectureSettings(for: [], destination: "platform=macOS").isEmpty)
    #expect(BuildDriver.simulatorArchitectureSettings(for: [], destination: nil).isEmpty)
    for own in ["ARCHS=x86_64", "ONLY_ACTIVE_ARCH=NO"] {
        #expect(
            BuildDriver.simulatorArchitectureSettings(for: [own], destination: "platform=iOS Simulator,id=X").isEmpty
        )
    }
    let driver = try BuildDriver(root: "/r", scheme: "App", destination: "platform=iOS Simulator,id=X")
    #expect(driver.buildCommand(workspace: "/w", artifacts: "/a").arguments.contains("ONLY_ACTIVE_ARCH=YES"))
}
