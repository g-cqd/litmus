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

@Test func `xcode builds and tests disable code coverage unless the caller passed it`() throws {
    let driver = try BuildDriver(root: "/r", scheme: "App", destination: "platform=iOS Simulator,id=X")
    let build = driver.buildCommand(workspace: "/w", artifacts: "/a").arguments
    let test = try driver.testCommand(workspace: "/w", artifacts: "/a", result: "/r", xctestrun: "/x.xctestrun")
        .arguments
    #expect(build.contains("-enableCodeCoverage") && build.contains("NO"))
    #expect(test.contains("-enableCodeCoverage") && test.contains("NO"))
    var explicit = driver
    explicit.xcodebuildArguments = ["-enableCodeCoverage", "YES"]
    let explicitBuild = explicit.buildCommand(workspace: "/w", artifacts: "/a").arguments
    #expect(explicitBuild.filter { $0 == "-enableCodeCoverage" }.count == 1)
    #expect(explicitBuild.contains("YES"))
}

@Test func `snapshot skips Finder metadata so .DS_Store cannot make evidence stale`() {
    #expect(WorkspaceSnapshot.limits.skippedNames.contains(".DS_Store"))
}

@Test func `simulator direct harness strips xcode injection vars and exposes app-hosted dyld paths`() {
    let harness = SimulatorDirectHarness(
        executor: BoundedExecutor(),
        fleet: .single(udid: "U", directory: "/w"),
        bundles: [
            .init(
                module: "AppTests",
                binary: "/P/App.app/PlugIns/AppTests.xctest/AppTests",
                products: "/P",
                hostApp: "/P/App.app",
                environment: [
                    "DYLD_INSERT_LIBRARIES": "/P/App.app/Frameworks/libXCTestBundleInject.dylib",
                    "XCInjectBundleInto": "unused",
                    "CUSTOM_VAR": "kept",
                ]
            )
        ],
        helper: .init(helper: "/h", simctl: "/usr/bin/simctl", frameworks: "/F", libraries: "/L", platforms: "/Plat"),
        workspace: "/w",
        logs: "/logs",
        workers: 4
    )
    #expect(harness.hasAppHostedTargets)
    #expect(harness.capabilities.maximumWorkers == 4)
    let env = harness.environment(nil, bundle: harness.bundles[0])
    #expect(env["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"] == nil)
    #expect(env["SIMCTL_CHILD_XCInjectBundleInto"] == nil)
    #expect(env["SIMCTL_CHILD_CUSTOM_VAR"] == "kept")
    #expect(env["SIMCTL_CHILD_DYLD_FRAMEWORK_PATH"]?.contains("/P/App.app:/P/App.app/Frameworks") == true)
    #expect(env["SIMCTL_CHILD_DYLD_LIBRARY_PATH"]?.contains("/P/App.app:/P/App.app/Frameworks") == true)
}
