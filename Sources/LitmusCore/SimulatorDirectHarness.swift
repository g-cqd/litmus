internal import Foundation
internal import SourceCorpus

/// Runs hostless test bundles on a booted simulator through Litmus's helper: `simctl spawn` per bundle, Swift
/// Testing through its ABI entry point with structured events (fail-fast, test names, filters, repetitions), XCTest
/// through `XCTestSuite`. Measured 3.3–4.3 s per run against 9–11 s for `xcodebuild test-without-building`.
/// One worker per simulator of its fleet: the user's one, or several Litmus made.
public struct SimulatorDirectHarness<Executor: ProcessExecutor>: TestHarness {
    struct Bundle: Sendable, Equatable {
        let module: String
        let binary: String
        let products: String
        /// The hosting `.app` bundle when Xcode built the test bundle with a `TEST_HOST`; nil for hostless bundles.
        let hostApp: String?
        let environment: [String: String]
    }

    let executor: Executor

    let fleet: SimulatorFleet

    let bundles: [Bundle]

    let helper: SimulatorHelper.Built

    let workspace: String

    let logs: String

    let workers: Int

    /// Whether any target is hosted by an application (its baseline must pass without UIApplication; if not, the
    /// runner falls back to `xcodebuild` automatically).
    var hasAppHostedTargets: Bool { bundles.contains { $0.hostApp != nil } }

    public var capabilities: HarnessCapabilities {
        HarnessCapabilities(
            maximumWorkers: max(fleet.count, workers),
            selectsTests: true,
            selectsModules: true,
            controlsSwiftTesting: true
        )
    }

    public var kind: String { "simulator-direct" }

    /// The simulator id of an Xcode destination (`id=<UDID>`), or nil.
    static func simulatorID(_ destination: String) -> String? {
        guard destination.contains("Simulator") || destination.contains("simulator") || destination.hasPrefix("id=")
        else { return nil }
        for field in destination.split(separator: ",") {
            let pair = field.split(separator: "=", maxSplits: 1)
            if pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces) == "id" {
                let id = pair[1].trimmingCharacters(in: .whitespaces)
                if id.count == 36, id.allSatisfy({ $0.isHexDigit || $0 == "-" }) { return id }
            }
        }
        return nil
    }

    /// The bundles of `targets`, or nil when one is a UI test (then `xcodebuild` runs them).
    /// Both hostless bundles and app-hosted unit test bundles are returned; for app-hosted bundles `hostApp` points to
    /// the `.app` directory so `dlopen` finds `<App>.debug.dylib` and embedded frameworks, and `probe()` plus the
    /// baseline check verify that the bundle runs without launching the application host.
    static func bundles(_ targets: [XCTestRunTarget]) -> [Bundle]? {
        guard !targets.isEmpty, targets.allSatisfy({ !$0.isUITest }) else { return nil }
        return targets.map { target in
            let name = ((target.bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
            let hostApp = target.isHostless ? nil : target.hostPath
            let products =
                hostApp.map { ($0 as NSString).deletingLastPathComponent }
                ?? (target.bundlePath as NSString).deletingLastPathComponent
            return Bundle(
                module: target.name,
                binary: target.bundlePath + "/" + name,
                products: products,
                hostApp: hostApp,
                environment: target.environment
            )
        }
    }

    /// The configuration Swift Testing's entry point reads (its command-line arguments as JSON).
    static func configuration(_ request: TestRunRequest) -> String {
        var object: [String: Any] = [:]
        if let only = request.onlySwiftTesting { object["filter"] = only.map(filterPattern(for:)) }
        if !request.skipSwiftTesting.isEmpty { object["skip"] = request.skipSwiftTesting.map(filterPattern(for:)) }
        if let repetitions = request.repetitions { object["repetitions"] = repetitions }
        let width = request.collectPerTestReach ? 1 : request.parallelizationWidth
        if let width { object["experimentalMaximumParallelizationWidth"] = width }
        // XCTest cases run with the whole suite only, as the direct harness runs them.
        object["xctest"] = request.onlySwiftTesting == nil
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    func environment(_ request: TestRunRequest?, bundle: Bundle) -> [String: String] {
        var environment: [String: String] = [:]
        if let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] {
            environment["DEVELOPER_DIR"] = developer
        }
        var child = bundle.environment
        // Xcode's test-runner injection libraries hook into `xcodebuild`'s testmanagerd; our helper runs directly.
        for key in [
            "DYLD_INSERT_LIBRARIES", "XCInjectBundleInto", "IDE_CHOSEN_LOGGING_METHOD",
            "__XPC_DYLD_FRAMEWORK_PATH", "__XPC_DYLD_LIBRARY_PATH",
        ] { child.removeValue(forKey: key) }
        let hostDirectories = bundle.hostApp.map { [$0, $0 + "/Frameworks"] } ?? []
        child["DYLD_FRAMEWORK_PATH"] =
            ([bundle.products, bundle.products + "/PackageFrameworks"] + hostDirectories + [helper.frameworks]).joined(
                separator: ":"
            )
        child["DYLD_LIBRARY_PATH"] = ([bundle.products] + hostDirectories + [helper.libraries]).joined(separator: ":")
        for (name, value) in subjectEnvironment(request) where name != "DEVELOPER_DIR" { child[name] = value }
        for (name, value) in child { environment["SIMCTL_CHILD_" + name] = value }
        // `simctl` itself carries the run's token too, so its session cleanup finds what it started.
        if let request { environment[processTokenVariable] = request.coverageDirectory }
        return environment
    }

    /// `events` may be the per-test reach FIFO; the helper's XCTest lines always go to `xctestEvents`, a regular file.
    func spawnCommand(
        udid: String,
        bundle: Bundle,
        events: String,
        xctestEvents: String,
        configuration: String
    ) -> ToolCommand {
        let spawn = ["spawn", udid, helper.helper, bundle.binary, events, configuration, xctestEvents]
        if helper.simctl == "/usr/bin/xcrun" {
            return ToolCommand(executable: "/usr/bin/xcrun", arguments: ["simctl"] + spawn)
        }
        return ToolCommand(executable: helper.simctl, arguments: spawn)
    }

    /// Whether the helper can run the first bundle on every device in `fleet`: a run that matches no test warms each
    /// freshly booted simulator so the real baseline never hits a first-boot SIGTERM. Anything else means `xcodebuild`.
    func probe() async throws -> Bool {
        guard let bundle = bundles.first else { return false }
        var seen: Set<String> = []
        for _ in 0..<max(1, fleet.count) {
            let udid = await fleet.nextDevice().udid
            guard seen.insert(udid).inserted else { continue }
            if !(try await probe(bundle, on: udid)) { return false }
        }
        return true
    }

    func probe(_ bundle: Bundle, on udid: String) async throws -> Bool {
        for attempt in 1...2 {
            let suffix = fleet.count > 1 ? "-\(udid.prefix(8))" : ""
            let events = logs + "/simulator-probe\(suffix).events.jsonl"
            let output = try await executor.execute(
                spawnCommand(
                    udid: udid,
                    bundle: bundle,
                    events: events,
                    xctestEvents: events + ".xctest",
                    configuration: #"{"filter":["^litmus-probe-matches-nothing$"],"xctest":false}"#
                ),
                directory: workspace,
                environment: environment(nil, bundle: bundle),
                timeout: 120
            )
            try writeLog(output, path: logs + "/simulator-probe\(suffix).log")
            let scan = try? TestEvidence.swiftTestingEvents(BoundedFileReader.read(path: events, cap: 1 << 20))
            if output.exitStatus == 0 && scan?.ended == true { return true }
            if attempt == 1 { try? await Task.sleep(for: .seconds(1)) }
        }
        return false
    }
}
