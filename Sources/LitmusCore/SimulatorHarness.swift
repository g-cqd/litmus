internal import AemiIO
internal import AemiJSON
internal import Foundation
internal import IndexStoreSupport
internal import SourceCorpus

/// A test target of a built `.xctestrun`, its placeholders resolved.
struct XCTestRunTarget: Sendable, Equatable {
    let name: String
    let bundlePath: String
    let hostPath: String?
    let isUITest: Bool
    let environment: [String: String]

    /// No application hosts it: Xcode's own `xctest` agent runs the bundle (package tests, hostless unit tests).
    var isHostless: Bool { !isUITest && (hostPath == nil || hostPath?.hasSuffix("/Agents/xctest") == true) }

    /// The test targets of the `.xctestrun` at `path`, format 1 or 2; `products` replaces `__TESTROOT__`, `platforms`
    /// `__PLATFORMS__`.
    static func targets(xctestrun path: String, products: String, platforms: String) throws -> [XCTestRunTarget] {
        let bytes = try BoundedFileReader.read(path: path, cap: 4 << 20)
        // SAFETY: the API is marked unsafe for its optional output pointer. We pass nil; the input is owned bounded Data.
        let plist = try unsafe PropertyListSerialization.propertyList(from: Data(bytes), options: [], format: nil)
        func resolve(_ text: String) -> String {
            text.replacingOccurrences(of: "__TESTROOT__", with: products)
                .replacingOccurrences(of: "__PLATFORMS__", with: platforms)
        }
        var targets: [XCTestRunTarget] = []
        func visit(_ value: Any, name: String?, depth: Int) throws {
            guard depth <= 64 else { throw LitmusFailure("xctestrun nesting exceeds 64") }
            if let dictionary = value as? [String: Any] {
                if let bundle = dictionary["TestBundlePath"] as? String {
                    let hostPath = (dictionary["TestHostPath"] as? String).map(resolve)
                    func resolveTarget(_ text: String) -> String {
                        let resolved = resolve(text)
                        return hostPath.map { resolved.replacingOccurrences(of: "__TESTHOST__", with: $0) } ?? resolved
                    }
                    let environment = (dictionary["EnvironmentVariables"] as? [String: String] ?? [:])
                        .merging(dictionary["TestingEnvironmentVariables"] as? [String: String] ?? [:]) { a, _ in a }
                    targets.append(
                        XCTestRunTarget(
                            name: dictionary["BlueprintName"] as? String ?? name ?? "",
                            bundlePath: resolveTarget(bundle),
                            hostPath: hostPath,
                            isUITest: dictionary["IsUITestBundle"] as? Bool ?? false,
                            environment: environment.mapValues(resolveTarget)
                        )
                    )
                    return
                }
                for (key, child) in dictionary { try visit(child, name: key, depth: depth + 1) }
            } else if let array = value as? [Any] {
                for child in array { try visit(child, name: name, depth: depth + 1) }
            }
        }
        try visit(plist, name: nil, depth: 0)
        return targets.sorted { $0.name < $1.name }
    }
}

/// Builds the simulator test helper once per toolchain into the build directory (kept across runs with a
/// persistent workspace or `--build-directory`).
enum SimulatorHelper {
    struct Built: Sendable {
        let helper: String
        let simctl: String
        let frameworks: String
        let libraries: String
        let platforms: String
    }

    static func build(into directory: String, executor: some ProcessExecutor, logs: String) async throws -> Built {
        func query(_ arguments: [String]) async throws -> String {
            let output = try await executor.execute(
                ToolCommand(executable: "/usr/bin/xcrun", arguments: arguments),
                directory: directory,
                environment: subjectEnvironment(nil),
                timeout: 120
            )
            guard output.exitStatus == 0, !output.truncated else {
                throw LitmusFailure("`xcrun \(arguments.joined(separator: " "))` failed")
            }
            return String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let platform = try await query(["--sdk", "iphonesimulator", "--show-sdk-platform-path"])
        let sdk = try await query(["--sdk", "iphonesimulator", "--show-sdk-path"])
        let compiler = try await query(["--sdk", "iphonesimulator", "swiftc", "--version"])
        let resolvedSimctl = try? await query(["--find", "simctl"])
        let simctl = resolvedSimctl.flatMap { BinaryTrustChecker.isTrusted(at: $0) ? $0 : nil } ?? "/usr/bin/xcrun"
        #if arch(arm64)
            let architecture = "arm64"
        #else
            let architecture = "x86_64"
        #endif
        let frameworks = platform + "/Developer/Library/Frameworks"
        let key = Digest.sha256(Array((simulatorHelperSource + "\u{0}" + compiler + "\u{0}" + architecture).utf8))
        let cacheRoot: String = {
            if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.path {
                let candidate = caches + "/litmus/simulator-helper"
                if (try? FileManager.default.createDirectory(atPath: candidate, withIntermediateDirectories: true))
                    != nil
                {
                    return candidate
                }
            }
            return directory + "/litmus-simulator-helper"
        }()
        let home = cacheRoot + "/" + key.prefix(24)
        let helper = home + "/helper"
        let built = Built(
            helper: helper,
            simctl: simctl,
            frameworks: frameworks,
            libraries: platform + "/Developer/usr/lib",
            platforms: (platform as NSString).deletingLastPathComponent
        )
        if FileManager.default.isExecutableFile(atPath: helper), BinaryTrustChecker.isTrusted(at: helper) {
            return built
        }
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let partial = helper + ".partial-" + UUID().uuidString.prefix(8)
        let source = home + "/main-" + UUID().uuidString.prefix(8) + ".swift"
        defer {
            try? FileManager.default.removeItem(atPath: source)
            try? FileManager.default.removeItem(atPath: partial)
        }
        try AtomicFile.replace(at: source, with: Array(simulatorHelperSource.utf8), durability: .none)
        let output = try await executor.execute(
            ToolCommand(
                executable: "/usr/bin/xcrun",
                arguments: [
                    "--sdk", "iphonesimulator", "swiftc", "-parse-as-library", "-swift-version", "5", "-O",
                    "-target", "\(architecture)-apple-ios17.0-simulator", "-sdk", sdk, source,
                    "-o", partial, "-F", frameworks, "-Xlinker", "-framework", "-Xlinker", "XCTest",
                    "-Xlinker", "-framework", "-Xlinker", "Testing", "-Xlinker", "-rpath", "-Xlinker", frameworks,
                ]
            ),
            directory: home,
            environment: subjectEnvironment(nil),
            timeout: 600
        )
        try writeLog(output, path: logs + "/simulator-helper-build.log")
        guard output.exitStatus == 0, !output.timedOut else {
            throw LitmusFailure("the simulator test helper did not build (logs/simulator-helper-build.log)")
        }
        if !FileManager.default.isExecutableFile(atPath: helper) {
            try? FileManager.default.moveItem(atPath: partial, toPath: helper)
        }
        guard FileManager.default.isExecutableFile(atPath: helper) else {
            throw LitmusFailure("the simulator test helper could not be published at \(helper)")
        }
        return built
    }
}

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
    private func spawnCommand(
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

    private func probe(_ bundle: Bundle, on udid: String) async throws -> Bool {
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

    public func run(_ request: TestRunRequest) async throws -> TestRunResult {
        if workers > fleet.count {
            // Multiple `simctl spawn` processes run concurrently on the booted simulator(s) with isolated TMPDIR and
            // coverage directories; do not take an exclusive device lease or reboot a shared simulator when one child
            // process traps on an integer overflow.
            return try await run(request, on: await fleet.nextDevice().udid)
        }
        return try await fleet.withDevice { device in
            let result = try await self.run(request, on: device.udid)
            // Under `simctl spawn` (`simulator-direct`), an active mutant that traps (SIGTRAP on integer overflow or
            // force-unwrap) exits only its own helper process without wedging SpringBoard; only a timed-out helper
            // warrants rebooting an owned simulator.
            return (result, result.outcome == .timedOut)
        }
    }

    private func run(_ request: TestRunRequest, on udid: String) async throws -> TestRunResult {
        let start = ContinuousClock.now
        func elapsed() -> Int64 { nanoseconds(since: start) }
        func remaining() -> Int { max(1, request.deadline - Int(elapsed() / 1_000_000_000)) }
        var passed = 0, skipped = 0
        var evidence: [String] = []
        var failing: [String] = []
        var moduleCounts: [String: TestCounts] = [:]
        var currentModule: String?
        var scans: [TestEvidence.EventScan] = []
        func result(_ outcome: TestRunOutcome, _ counts: TestCounts?, _ reason: String) -> TestRunResult {
            var result = TestRunResult(
                outcome: outcome,
                counts: counts,
                nanoseconds: elapsed(),
                evidence: evidence,
                reason: reason
            )
            result.failingTests = failing
            result.moduleCounts = moduleCounts
            result.failedModule = outcome == .passed ? nil : currentModule
            for scan in scans { result.absorb(scan) }
            return result
        }
        for bundle in bundles {
            if let only = request.onlySwiftTesting, !only.contains(where: { $0.hasPrefix(bundle.module + ".") }) {
                continue
            }
            if let modules = request.onlyModules, !modules.contains(bundle.module) { continue }
            if request.skipModules.contains(bundle.module) { continue }
            currentModule = bundle.module
            let stem = "\(request.name)-\(bundle.module)-simulator"
            let events = "\(logs)/\(stem).events.jsonl"
            let configJSON = Self.configuration(request)
            let xctestEvents = events + ".xctest"
            try? FileManager.default.removeItem(atPath: xctestEvents)
            let (output, stopped) = try await runEventStream(
                executor: executor,
                request: request,
                stem: stem,
                events: events,
                directory: workspace,
                baseEnvironment: environment(request, bundle: bundle),
                traceKey: "SIMCTL_CHILD_"
                    + ActivationEnvironment.key(ActivationEnvironment.testTracePath, token: request.environmentToken),
                deadline: remaining()
            ) { streamPath in
                spawnCommand(
                    udid: udid,
                    bundle: bundle,
                    events: streamPath,
                    xctestEvents: xctestEvents,
                    configuration: configJSON
                )
            }
            if let output { try writeLog(output, path: "\(logs)/\(stem).log") }
            evidence += ["logs/\(stem).events.jsonl", "logs/\(stem).log"]
            let scan = try? TestEvidence.swiftTestingEvents(BoundedFileReader.read(path: events, cap: 64 << 20))
            if let scan { scans.append(scan) }
            failing += (scan?.failedTests ?? []).map(testName).sorted()
            let xctest = Self.xctestCounts(events + ".xctest")
            if FileManager.default.fileExists(atPath: events + ".xctest") {
                evidence.append("logs/\(stem).events.jsonl.xctest")
            }
            if stopped { return result(.failed, nil, "Swift Testing recorded a failing issue (stopped early)") }
            guard let output else { return result(.unusable, nil, "the simulator helper produced no process result") }
            if output.timedOut {
                return result(
                    .timedOut,
                    nil,
                    Self.timeoutReason(
                        deadline: request.deadline,
                        swiftTestingEnded: scan?.ended == true,
                        unfinished: Self.unfinishedXCTests(events + ".xctest")
                    )
                )
            }
            if scan?.failed == true || (xctest?.failed ?? 0) > 0 {
                return result(.failed, nil, "a test failed")
            }
            // A setup problem of the helper (64 and above, before any test ran) is not a crash of the code under test.
            if (64...68).contains(output.exitStatus), scan?.ended != true {
                return result(
                    .unusable,
                    nil,
                    "the simulator helper could not run \(bundle.module) (exit \(output.exitStatus))"
                )
            }
            if output.exitStatus != 0 || scan?.ended != true {
                return result(.crashed, nil, abnormalEnd(output, "the simulator test process"))
            }
            guard let scan else {
                return result(.unusable, nil, "the Swift Testing event stream of \(bundle.module) is unreadable")
            }
            let counts = scan.counts
            let bundlePassed = counts.passed + (xctest?.passed ?? 0)
            let bundleSkipped = counts.skipped + (xctest?.skipped ?? 0)
            passed += bundlePassed
            skipped += bundleSkipped
            let previous = moduleCounts[bundle.module] ?? TestCounts(passed: 0, failed: 0, skipped: 0)
            moduleCounts[bundle.module] = TestCounts(
                passed: previous.passed + bundlePassed,
                failed: 0,
                skipped: previous.skipped + bundleSkipped
            )
        }
        guard passed + skipped > 0 || !request.skipSwiftTesting.isEmpty else {
            return result(.unusable, nil, "the simulator helper ran no test")
        }
        return result(.passed, TestCounts(passed: passed, failed: 0, skipped: skipped), "every test passed")
    }

    /// The XCTest cases the helper recorded: `{"xctest":{"name":…,"status":"passed"|"failed"|"skipped"}}` lines.
    static func xctestCounts(_ path: String) -> TestCounts? {
        guard let events = xctestEvents(path) else { return nil }
        var passed = 0, failed = 0, skipped = 0
        for event in events {
            switch event.status {
            case "passed": passed += 1
            case "failed": failed += 1
            case "skipped": skipped += 1
            case "started": break
            default: return nil
            }
        }
        return TestCounts(passed: passed, failed: failed, skipped: skipped)
    }

    /// The XCTest cases the helper started and never finished, in start order: where a stalled run stopped.
    static func unfinishedXCTests(_ path: String) -> [String] {
        var started: [String] = []
        for event in xctestEvents(path) ?? [] {
            if event.status == "started" {
                started.append(event.name)
            } else {
                started.removeAll { $0 == event.name }
            }
        }
        return started
    }

    /// The `{"xctest":{"name":…,"status":…}}` lines of the helper's XCTest file, or nil when it is missing or malformed.
    private static func xctestEvents(_ path: String) -> [(name: String, status: String)]? {
        guard let bytes = try? BoundedFileReader.read(path: path, cap: 16 << 20) else { return nil }
        var events: [(name: String, status: String)] = []
        for line in bytes.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            guard let document = try? AemiJSON.parse(Array(line)), let status = document.root.xctest.status.string
            else { return nil }
            events.append((document.root.xctest.name.string ?? "", status))
        }
        return events
    }

    /// Why a run past its deadline stalled, from what the event files show.
    static func timeoutReason(deadline: Int, swiftTestingEnded: Bool, unfinished: [String]) -> String {
        let base = "the simulator run exceeded \(deadline) s"
        if let first = unfinished.first {
            return base + "; \(swiftTestingEnded ? "Swift Testing had finished, " : "")XCTest case \(first) had not"
        }
        return swiftTestingEnded ? base + "; every test had finished but the test process did not exit" : base
    }
}
