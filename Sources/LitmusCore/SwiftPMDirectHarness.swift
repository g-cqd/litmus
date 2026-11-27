internal import Foundation
internal import SourceCorpus

/// Runs a SwiftPM package's built test bundles directly, without `swift test`: no manifest evaluation per run and no
/// `.build` lock, so several mutants can run at once. Swift Testing runs through the toolchain's
/// `swiftpm-testing-helper` with an event stream (structured, streamed: fail-fast) and xUnit; XCTest runs through
/// `xctest -XCTest <classes>`, whose exit status is its structured result, as SwiftPM itself reads it.
public struct SwiftPMDirectHarness<Executor: ProcessExecutor>: TestHarness {
    /// One test bundle and the tests SwiftPM listed in it.
    public struct Bundle: Sendable, Equatable {
        public let module: String
        public let bundlePath: String
        public let binaryPath: String
        public let swiftTestingCount: Int
        public let xcTestClasses: [String]
        public let xcTestCount: Int
    }

    /// Absolute paths of the toolchain programs and the platform libraries they need.
    public struct Toolchain: Sendable, Equatable {
        public let xctest: String
        public let testingHelper: String
        public let frameworks: String
        public let libraries: String
    }

    let executor: Executor
    let bundles: [Bundle]
    let toolchain: Toolchain
    let workspace: String
    let logs: String
    public let capabilities: HarnessCapabilities
    public var kind: String { "swiftpm-direct" }

    public init(
        executor: Executor,
        bundles: [Bundle],
        toolchain: Toolchain,
        workspace: String,
        logs: String,
        workers: Int
    ) {
        self.executor = executor
        self.bundles = bundles
        self.toolchain = toolchain
        self.workspace = workspace
        self.logs = logs
        capabilities = HarnessCapabilities(
            maximumWorkers: workers,
            selectsTests: true,
            selectsModules: true,
            controlsSwiftTesting: true
        )
    }

    /// Groups `swift test list` lines by module and matches them to built bundles: `<Module>.xctest`, or the single
    /// bundle of an older layout. Returns nil when the layout is not understood, so the caller falls back to
    /// `swift test`.
    public static func bundles(listing: String, binPath: String) -> [Bundle]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: binPath) else { return nil }
        let built = names.filter { $0.hasSuffix(".xctest") }.sorted()
        guard !built.isEmpty else { return nil }
        var swiftTesting: [String: Int] = [:]
        var xcTest: [String: Set<String>] = [:]
        var xcTestCount: [String: Int] = [:]
        for line in listing.split(whereSeparator: \.isNewline).map(String.init) where !line.isEmpty {
            guard let dot = line.firstIndex(of: ".") else { return nil }
            let module = String(line[..<dot])
            if line.hasSuffix(")") {
                swiftTesting[module, default: 0] += 1
            } else {
                guard let slash = line.lastIndex(of: "/") else { return nil }
                xcTest[module, default: []].insert(String(line[..<slash]))
                xcTestCount[module, default: 0] += 1
            }
        }
        let modules = Set(swiftTesting.keys).union(xcTest.keys)
        guard !modules.isEmpty else { return nil }
        var result: [Bundle] = []
        for module in modules.sorted() {
            let name: String
            if built.contains(module + ".xctest") {
                name = module + ".xctest"
            } else if built.count == 1, modules.count == 1, let only = built.first {
                name = only
            } else {
                return nil
            }
            let bundle = binPath + "/" + name
            let binary = bundle + "/Contents/MacOS/" + String(name.dropLast(".xctest".count))
            guard FileManager.default.isExecutableFile(atPath: binary) else { return nil }
            result.append(
                Bundle(
                    module: module,
                    bundlePath: bundle,
                    binaryPath: binary,
                    swiftTestingCount: swiftTesting[module] ?? 0,
                    xcTestClasses: (xcTest[module] ?? []).sorted(),
                    xcTestCount: xcTestCount[module] ?? 0
                )
            )
        }
        return result
    }

    public func run(_ request: TestRunRequest) async throws -> TestRunResult {
        let start = ContinuousClock.now
        func elapsed() -> Int64 { nanoseconds(since: start) }
        func remaining() -> Int { max(1, request.deadline - Int(elapsed() / 1_000_000_000)) }
        var environment = subjectEnvironment(request)
        environment["DYLD_FRAMEWORK_PATH"] = toolchain.frameworks
        environment["DYLD_LIBRARY_PATH"] = toolchain.libraries
        var passed = 0, skipped = 0
        var evidence: [String] = []
        var failing: [String] = []
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
        var currentModule: String?
        var moduleCounts: [String: TestCounts] = [:]
        func count(_ module: String, passed: Int, skipped: Int) {
            let previous = moduleCounts[module] ?? TestCounts(passed: 0, failed: 0, skipped: 0)
            moduleCounts[module] = TestCounts(
                passed: previous.passed + passed,
                failed: 0,
                skipped: previous.skipped + skipped
            )
        }
        for bundle in bundles {
            if let only = request.onlySwiftTesting, !only.contains(where: { $0.hasPrefix(bundle.module + ".") }) {
                continue
            }
            if let modules = request.onlyModules, !modules.contains(bundle.module) { continue }
            if request.skipModules.contains(bundle.module) { continue }
            currentModule = bundle.module
            if bundle.swiftTestingCount > 0 {
                let stem = "\(request.name)-\(bundle.module)-swift-testing"
                let events = "\(logs)/\(stem).events.jsonl", xunit = "\(logs)/\(stem).xml"
                var filters = (request.onlySwiftTesting ?? []).flatMap { ["--filter", filterPattern(for: $0)] }
                filters += request.skipSwiftTesting.flatMap { ["--skip", filterPattern(for: $0)] }
                if let repetitions = request.repetitions { filters += ["--repetitions", String(repetitions)] }
                if let width = request.collectPerTestReach ? 1 : request.parallelizationWidth {
                    filters += ["--experimental-maximum-parallelization-width", String(width)]
                }
                let (output, stopped) = try await runEventStream(
                    executor: executor,
                    request: request,
                    stem: stem,
                    events: events,
                    directory: workspace,
                    baseEnvironment: environment,
                    traceKey: ActivationEnvironment.key(
                        ActivationEnvironment.testTracePath,
                        token: request.environmentToken
                    ),
                    deadline: remaining()
                ) { streamPath in
                    ToolCommand(
                        executable: toolchain.testingHelper,
                        arguments: [
                            "--test-bundle-path", bundle.binaryPath, "--testing-library", "swift-testing",
                            "--event-stream-output-path", streamPath, "--event-stream-version", "0",
                            "--xunit-output", xunit,
                        ] + filters
                    )
                }
                if let output { try writeLog(output, path: "\(logs)/\(stem).log") }
                evidence += ["logs/\(stem).events.jsonl", "logs/\(stem).log"]
                let scan = try? TestEvidence.swiftTestingEvents(
                    BoundedFileReader.read(path: events, cap: 64 << 20)
                )
                if let scan { scans.append(scan) }
                failing += (scan?.failedTests ?? []).map(testName).sorted()
                if stopped { return result(.failed, nil, "Swift Testing recorded a failing issue (stopped early)") }
                guard let output else { return result(.unusable, nil, "Swift Testing produced no process result") }
                if output.timedOut { return result(.timedOut, nil, "Swift Testing exceeded \(request.deadline) s") }
                // Counts come from the event stream. The xUnit report only cross-checks them when it is well-formed:
                // the toolchain writes a test name holding `"` into an attribute unescaped (seen on ask, 2026-11-02).
                var xunitCounts: TestCounts?
                if FileManager.default.fileExists(atPath: xunit) {
                    evidence.append("logs/\(stem).xml")
                    xunitCounts = try? TestEvidence.xunit(BoundedFileReader.read(path: xunit, cap: 16 << 20))
                }
                if output.exceededMemory { return result(.crashed, nil, abnormalEnd(output, "Swift Testing")) }
                if scan?.failed == true || (xunitCounts?.failed ?? 0) > 0 {
                    return result(.failed, nil, "Swift Testing recorded a failing issue")
                }
                if output.exitStatus != 0 { return result(.crashed, nil, abnormalEnd(output, "Swift Testing")) }
                guard let scan else {
                    return result(.unusable, nil, "the Swift Testing event stream of \(bundle.module) is unreadable")
                }
                guard scan.ended else {
                    return result(.unusable, nil, "the Swift Testing event stream of \(bundle.module) has no runEnded")
                }
                let counts = scan.counts
                guard counts.total > 0 || request.onlySwiftTesting == nil && !request.skipSwiftTesting.isEmpty else {
                    return result(.unusable, nil, "Swift Testing ran no test of \(bundle.module)")
                }
                if let xunitCounts, xunitCounts != counts {
                    return result(
                        .unusable,
                        nil,
                        "Swift Testing counts disagree for \(bundle.module): event stream \(counts.passed) passed, "
                            + "\(counts.skipped) skipped; xUnit \(xunitCounts.passed) passed, \(xunitCounts.skipped) skipped"
                    )
                }
                passed += counts.passed
                skipped += counts.skipped
                count(bundle.module, passed: counts.passed, skipped: counts.skipped)
            }
            if !bundle.xcTestClasses.isEmpty, request.onlySwiftTesting == nil {
                let stem = "\(request.name)-\(bundle.module)-xctest"
                let command = ToolCommand(
                    executable: toolchain.xctest,
                    arguments: ["-XCTest", bundle.xcTestClasses.joined(separator: ","), bundle.bundlePath]
                )
                let output = try await executor.execute(
                    command,
                    directory: workspace,
                    environment: environment,
                    timeout: remaining(),
                    supervision: request.supervision
                )
                try writeLog(output, path: "\(logs)/\(stem).log")
                evidence.append("logs/\(stem).log")
                if output.timedOut { return result(.timedOut, nil, "XCTest exceeded \(request.deadline) s") }
                // A signal, not a status of 128 or more, tells a crash: a test runner may exit 134 itself.
                if output.terminationSignal != nil || output.exceededMemory {
                    return result(.crashed, nil, abnormalEnd(output, "XCTest"))
                }
                switch output.exitStatus {
                case 0:
                    passed += bundle.xcTestCount
                    count(bundle.module, passed: bundle.xcTestCount, skipped: 0)
                case 1: return result(.failed, nil, "XCTest reported a failing test (exit 1)")
                default: return result(.unusable, nil, "xctest exited \(output.exitStatus)")
                }
            }
        }
        return result(.passed, TestCounts(passed: passed, failed: 0, skipped: skipped), "every listed test passed")
    }
}
