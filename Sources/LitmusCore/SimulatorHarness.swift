internal import AemiIO
internal import AemiJSON
internal import Foundation
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
                    let environment = (dictionary["EnvironmentVariables"] as? [String: String] ?? [:])
                        .merging(dictionary["TestingEnvironmentVariables"] as? [String: String] ?? [:]) { a, _ in a }
                    targets.append(
                        XCTestRunTarget(
                            name: dictionary["BlueprintName"] as? String ?? name ?? "",
                            bundlePath: resolve(bundle),
                            hostPath: (dictionary["TestHostPath"] as? String).map(resolve),
                            isUITest: dictionary["IsUITestBundle"] as? Bool ?? false,
                            environment: environment.mapValues(resolve)
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
        #if arch(arm64)
            let architecture = "arm64"
        #else
            let architecture = "x86_64"
        #endif
        let frameworks = platform + "/Developer/Library/Frameworks"
        let key = Digest.sha256(Array((simulatorHelperSource + "\u{0}" + compiler + "\u{0}" + architecture).utf8))
        let home = directory + "/litmus-simulator-helper/" + key.prefix(24)
        let helper = home + "/helper"
        let built = Built(
            helper: helper,
            frameworks: frameworks,
            libraries: platform + "/Developer/usr/lib",
            platforms: (platform as NSString).deletingLastPathComponent
        )
        if FileManager.default.isExecutableFile(atPath: helper) { return built }
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try AtomicFile.replace(at: home + "/main.swift", with: Array(simulatorHelperSource.utf8), durability: .none)
        let output = try await executor.execute(
            ToolCommand(
                executable: "/usr/bin/xcrun",
                arguments: [
                    "--sdk", "iphonesimulator", "swiftc", "-parse-as-library", "-swift-version", "5", "-O",
                    "-target", "\(architecture)-apple-ios17.0-simulator", "-sdk", sdk, home + "/main.swift",
                    "-o", helper + ".partial", "-F", frameworks, "-Xlinker", "-framework", "-Xlinker", "XCTest",
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
        try FileManager.default.moveItem(atPath: helper + ".partial", toPath: helper)
        return built
    }
}

/// Runs hostless test bundles on a booted simulator through Litmus's helper (t58): `simctl spawn` per bundle, Swift
/// Testing through its ABI entry point with structured events (fail-fast, test names, filters, repetitions), XCTest
/// through `XCTestSuite`. Measured 3.3–4.3 s per run against 9–11 s for `xcodebuild test-without-building` (phase 0).
/// One worker: one simulator.
public struct SimulatorDirectHarness<Executor: ProcessExecutor>: TestHarness {
    struct Bundle: Sendable, Equatable {
        let module: String
        let binary: String
        let products: String
        let environment: [String: String]
    }

    let executor: Executor
    let udid: String
    let bundles: [Bundle]
    let helper: SimulatorHelper.Built
    let workspace: String
    let logs: String
    public var maximumWorkers: Int { 1 }
    public var kind: String { "simulator-direct" }
    public var selectsTests: Bool { true }
    public var selectsModules: Bool { true }
    public var controlsSwiftTesting: Bool { true }

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

    /// The bundles of `targets`, or nil when one is hosted by an application or a UI test (then `xcodebuild` runs them).
    static func bundles(_ targets: [XCTestRunTarget]) -> [Bundle]? {
        guard !targets.isEmpty, targets.allSatisfy(\.isHostless) else { return nil }
        return targets.map { target in
            let name = ((target.bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
            return Bundle(
                module: target.name,
                binary: target.bundlePath + "/" + name,
                products: (target.bundlePath as NSString).deletingLastPathComponent,
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
        if let width = request.parallelizationWidth { object["experimentalMaximumParallelizationWidth"] = width }
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
        child["DYLD_FRAMEWORK_PATH"] = [bundle.products, bundle.products + "/PackageFrameworks", helper.frameworks]
            .joined(separator: ":")
        child["DYLD_LIBRARY_PATH"] = [bundle.products, helper.libraries].joined(separator: ":")
        for (name, value) in subjectEnvironment(request) where name != "DEVELOPER_DIR" { child[name] = value }
        for (name, value) in child { environment["SIMCTL_CHILD_" + name] = value }
        // `simctl` itself carries the run's token too, so its session cleanup finds what it started.
        if let request { environment[processTokenVariable] = request.coverageDirectory }
        return environment
    }

    /// Whether the helper can run the first bundle at all (entry point found, bundle loaded): a run that matches no
    /// test. Anything else means `xcodebuild`.
    func probe() async throws -> Bool {
        guard let bundle = bundles.first else { return false }
        let events = logs + "/simulator-probe.events.jsonl"
        let output = try await executor.execute(
            ToolCommand(
                executable: "/usr/bin/xcrun",
                arguments: [
                    "simctl", "spawn", udid, helper.helper, bundle.binary, events,
                    #"{"filter":["^litmus-probe-matches-nothing$"],"xctest":false}"#,
                ]
            ),
            directory: workspace,
            environment: environment(nil, bundle: bundle),
            timeout: 120
        )
        try writeLog(output, path: logs + "/simulator-probe.log")
        let scan = try? TestEvidence.swiftTestingEvents(BoundedFileReader.read(path: events, cap: 1 << 20))
        return output.exitStatus == 0 && scan?.ended == true
    }

    public func run(_ request: TestRunRequest) async throws -> TestRunResult {
        let start = ContinuousClock.now
        func elapsed() -> Int64 {
            let duration = ContinuousClock.now - start
            return duration.components.seconds * 1_000_000_000 + duration.components.attoseconds / 1_000_000_000
        }
        func remaining() -> Int { max(1, request.deadline - Int(elapsed() / 1_000_000_000)) }
        var passed = 0, skipped = 0
        var evidence: [String] = []
        var failing: [String] = []
        var moduleCounts: [String: TestCounts] = [:]
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
            return result
        }
        for bundle in bundles {
            if let only = request.onlySwiftTesting, !only.contains(where: { $0.hasPrefix(bundle.module + ".") }) {
                continue
            }
            if let modules = request.onlyModules, !modules.contains(bundle.module) { continue }
            let stem = "\(request.name)-\(bundle.module)-simulator"
            let events = "\(logs)/\(stem).events.jsonl"
            let command = ToolCommand(
                executable: "/usr/bin/xcrun",
                arguments: ["simctl", "spawn", udid, helper.helper, bundle.binary, events, Self.configuration(request)]
            )
            let (output, stopped) = try await runWatching(
                executor,
                command,
                directory: workspace,
                environment: environment(request, bundle: bundle),
                deadline: remaining(),
                events: events,
                failFast: request.failFast,
                supervision: request.supervision
            )
            if let output { try writeLog(output, path: "\(logs)/\(stem).log") }
            evidence += ["logs/\(stem).events.jsonl", "logs/\(stem).log"]
            let scan = try? TestEvidence.swiftTestingEvents(BoundedFileReader.read(path: events, cap: 64 << 20))
            failing += (scan?.failedTests ?? []).map(testName).sorted()
            let xctest = Self.xctestCounts(events + ".xctest")
            if FileManager.default.fileExists(atPath: events + ".xctest") {
                evidence.append("logs/\(stem).events.jsonl.xctest")
            }
            if stopped { return result(.failed, nil, "Swift Testing recorded a failing issue (stopped early)") }
            guard let output else { return result(.unusable, nil, "the simulator helper produced no process result") }
            if output.timedOut { return result(.timedOut, nil, "the simulator run exceeded \(request.deadline) s") }
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
        guard let bytes = try? BoundedFileReader.read(path: path, cap: 16 << 20) else { return nil }
        var passed = 0, failed = 0, skipped = 0
        for line in bytes.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            guard let document = try? AemiJSON.parse(Array(line)), let status = document.root.xctest.status.string
            else { return nil }
            switch status {
            case "passed": passed += 1
            case "failed": failed += 1
            case "skipped": skipped += 1
            default: return nil
            }
        }
        return TestCounts(passed: passed, failed: failed, skipped: skipped)
    }
}
