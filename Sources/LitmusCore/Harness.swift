internal import Foundation
internal import SourceCorpus

/// One test-suite execution against the current build.
public struct TestRunRequest: Sendable {
    /// File prefix for this run's evidence in the run's `logs` directory.
    public let name: String
    /// The mutant to activate, or empty for an inactive control.
    public let activeID: String
    /// A fresh directory for activation markers.
    public let coverageDirectory: String
    /// A fresh `TMPDIR`, so tests that use fixed temporary names do not collide across workers.
    public let temporaryDirectory: String
    /// Deadline for the whole suite, in seconds.
    public let deadline: Int
    /// Stop at the first structured test failure (Swift Testing event stream).
    public let failFast: Bool
}

/// What a suite execution showed, before activation is considered.
public enum TestRunOutcome: String, Codable, Sendable {
    case passed, failed, crashed, timedOut, unusable
}

/// The structured result of one suite execution.
public struct TestRunResult: Sendable {
    public let outcome: TestRunOutcome
    /// Complete counts; nil after a fail-fast stop or a crash.
    public let counts: TestCounts?
    public let nanoseconds: Int64
    /// Evidence files, relative to the run directory.
    public let evidence: [String]
    public let reason: String
}

/// Runs the subject's tests against the current build products.
public protocol TestHarness: Sendable {
    /// Workers that may run at once against one build.
    var maximumWorkers: Int { get }
    /// A description for provenance.
    var kind: String { get }
    func run(_ request: TestRunRequest) async throws -> TestRunResult
}

/// The common environment of every subject process: the selector, the marker directory, a private `TMPDIR`, and the
/// developer directory analyzerkit's scrubbing would drop.
func subjectEnvironment(_ request: TestRunRequest?) -> [String: String] {
    var environment = [ActivationEnvironment.activeID: request?.activeID ?? ""]
    if let request {
        environment[ActivationEnvironment.coverageDirectory] = request.coverageDirectory
        environment["TMPDIR"] = request.temporaryDirectory
    }
    if let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] { environment["DEVELOPER_DIR"] = developer }
    return environment
}

func writeLog(_ result: ProcessOutput, path: String) throws {
    let header = "exit=\(result.exitStatus) timeout=\(result.timedOut) truncated=\(result.truncated)\n--- stdout ---\n"
    let bytes = Array(header.utf8) + result.stdout + Array("\n--- stderr ---\n".utf8) + result.stderr
    try Data(bytes).write(to: URL(fileURLWithPath: path), options: .atomic)
}

/// Which child of the fail-fast race finished first.
private enum Race: Sendable {
    case finished(ProcessOutput)
    case failure
    /// The stream could not be read as events; the run continues and is judged by its final evidence.
    case stoppedWatching
}

/// Runs a process while watching a Swift Testing event stream; on the first failing issue the process group is
/// cancelled (analyzerkit's `BoundedProcess` terminates it, TERM then KILL).
func runWatching(
    _ executor: some ProcessExecutor,
    _ command: ToolCommand,
    directory: String,
    environment: [String: String],
    deadline: Int,
    events: String?,
    failFast: Bool
) async throws -> (output: ProcessOutput?, stoppedOnFailure: Bool) {
    guard failFast, let events else {
        let output = try await executor.execute(
            command,
            directory: directory,
            environment: environment,
            timeout: deadline
        )
        return (output, false)
    }
    return try await withThrowingTaskGroup(of: Race.self) { group in
        group.addTask {
            .finished(
                try await executor.execute(command, directory: directory, environment: environment, timeout: deadline)
            )
        }
        group.addTask {
            var offset: UInt64 = 0
            var pending: [UInt8] = []
            while !Task.isCancelled {
                try await Task.sleep(for: .milliseconds(15))
                guard let handle = FileHandle(forReadingAtPath: events) else { continue }
                defer { try? handle.close() }
                try handle.seek(toOffset: offset)
                let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
                offset += UInt64(chunk.count)
                pending += chunk
                guard let scan = try? TestEvidence.swiftTestingEvents(pending), pending.count < 4 << 20 else {
                    return .stoppedWatching
                }
                if scan.failed { return .failure }
                pending.removeFirst(scan.consumed)
            }
            throw CancellationError()
        }
        var output: ProcessOutput?
        var stopped = false
        while true {
            do {
                guard let next = try await group.next() else { break }
                switch next {
                case .finished(let finished):
                    output = finished
                    group.cancelAll()
                case .failure:
                    stopped = true
                    group.cancelAll()
                case .stoppedWatching:
                    break
                }
            } catch is CancellationError {
                // The losing child of the race; a cancellation of the caller is rethrown below.
            }
        }
        try Task.checkCancellation()
        return (output, stopped)
    }
}

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
    public let maximumWorkers: Int
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
        maximumWorkers = max(1, workers)
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
        func elapsed() -> Int64 {
            let duration = ContinuousClock.now - start
            return duration.components.seconds * 1_000_000_000 + duration.components.attoseconds / 1_000_000_000
        }
        func remaining() -> Int { max(1, request.deadline - Int(elapsed() / 1_000_000_000)) }
        var environment = subjectEnvironment(request)
        environment["DYLD_FRAMEWORK_PATH"] = toolchain.frameworks
        environment["DYLD_LIBRARY_PATH"] = toolchain.libraries
        var passed = 0, skipped = 0
        var evidence: [String] = []
        func result(_ outcome: TestRunOutcome, _ counts: TestCounts?, _ reason: String) -> TestRunResult {
            TestRunResult(outcome: outcome, counts: counts, nanoseconds: elapsed(), evidence: evidence, reason: reason)
        }
        for bundle in bundles {
            if bundle.swiftTestingCount > 0 {
                let stem = "\(request.name)-\(bundle.module)-swift-testing"
                let events = "\(logs)/\(stem).events.jsonl", xunit = "\(logs)/\(stem).xml"
                let command = ToolCommand(
                    executable: toolchain.testingHelper,
                    arguments: [
                        "--test-bundle-path", bundle.binaryPath, "--testing-library", "swift-testing",
                        "--event-stream-output-path", events, "--event-stream-version", "0", "--xunit-output", xunit,
                    ]
                )
                let (output, stopped) = try await runWatching(
                    executor,
                    command,
                    directory: workspace,
                    environment: environment,
                    deadline: remaining(),
                    events: events,
                    failFast: request.failFast
                )
                if let output { try writeLog(output, path: "\(logs)/\(stem).log") }
                evidence += ["logs/\(stem).events.jsonl", "logs/\(stem).log"]
                if stopped { return result(.failed, nil, "Swift Testing recorded a failing issue (stopped early)") }
                guard let output else { return result(.unusable, nil, "Swift Testing produced no process result") }
                if output.timedOut { return result(.timedOut, nil, "Swift Testing exceeded \(request.deadline) s") }
                let scan = try? TestEvidence.swiftTestingEvents(
                    BoundedFileReader.read(path: events, cap: 64 << 20)
                )
                let counts =
                    FileManager.default.fileExists(atPath: xunit)
                    ? try? TestEvidence.xunit(BoundedFileReader.read(path: xunit, cap: 16 << 20)) : nil
                if FileManager.default.fileExists(atPath: xunit) { evidence.append("logs/\(stem).xml") }
                if scan?.failed == true || (counts?.failed ?? 0) > 0 {
                    return result(.failed, nil, "Swift Testing recorded a failing issue")
                }
                if output.exitStatus != 0 {
                    return result(.crashed, nil, "Swift Testing exited \(output.exitStatus) without a recorded failure")
                }
                guard let counts, scan?.ended == true, counts.total > 0 else {
                    return result(.unusable, nil, "Swift Testing evidence incomplete for \(bundle.module)")
                }
                passed += counts.passed
                skipped += counts.skipped
            }
            if !bundle.xcTestClasses.isEmpty {
                let stem = "\(request.name)-\(bundle.module)-xctest"
                let command = ToolCommand(
                    executable: toolchain.xctest,
                    arguments: ["-XCTest", bundle.xcTestClasses.joined(separator: ","), bundle.bundlePath]
                )
                let output = try await executor.execute(
                    command,
                    directory: workspace,
                    environment: environment,
                    timeout: remaining()
                )
                try writeLog(output, path: "\(logs)/\(stem).log")
                evidence.append("logs/\(stem).log")
                if output.timedOut { return result(.timedOut, nil, "XCTest exceeded \(request.deadline) s") }
                switch output.exitStatus {
                case 0: passed += bundle.xcTestCount
                case 1: return result(.failed, nil, "XCTest reported a failing test (exit 1)")
                case 128...: return result(.crashed, nil, "XCTest terminated by signal \(output.exitStatus - 128)")
                default: return result(.unusable, nil, "xctest exited \(output.exitStatus)")
                }
            }
        }
        return result(.passed, TestCounts(passed: passed, failed: 0, skipped: skipped), "every listed test passed")
    }
}

/// Runs `swift test` per execution: the conservative fallback when bundles cannot be run directly. One worker, because
/// SwiftPM locks the scratch directory.
public struct SwiftPMToolHarness<Executor: ProcessExecutor>: TestHarness {
    let executor: Executor
    let driver: BuildDriver
    let workspace: String
    let artifacts: String
    let logs: String
    public var maximumWorkers: Int { 1 }
    public var kind: String { "swift-test" }

    public init(executor: Executor, driver: BuildDriver, workspace: String, artifacts: String, logs: String) {
        self.executor = executor
        self.driver = driver
        self.workspace = workspace
        self.artifacts = artifacts
        self.logs = logs
    }

    public func run(_ request: TestRunRequest) async throws -> TestRunResult {
        let start = ContinuousClock.now
        let xunit = "\(logs)/\(request.name).xml"
        let command = try driver.testCommand(workspace: workspace, artifacts: artifacts, result: xunit)
        let output = try await executor.execute(
            command,
            directory: workspace,
            environment: subjectEnvironment(request),
            timeout: request.deadline
        )
        try writeLog(output, path: "\(logs)/\(request.name).log")
        let duration = ContinuousClock.now - start
        let nanoseconds = duration.components.seconds * 1_000_000_000 + duration.components.attoseconds / 1_000_000_000
        var evidence = ["logs/\(request.name).log"]
        func result(_ outcome: TestRunOutcome, _ counts: TestCounts?, _ reason: String) -> TestRunResult {
            TestRunResult(
                outcome: outcome,
                counts: counts,
                nanoseconds: nanoseconds,
                evidence: evidence,
                reason: reason
            )
        }
        if output.timedOut { return result(.timedOut, nil, "swift test exceeded \(request.deadline) s") }
        guard let reports = try? TestEvidence.swiftPM(at: xunit) else {
            return output.exitStatus == 0
                ? result(.unusable, nil, "no structured test result")
                : result(.crashed, nil, "swift test exited \(output.exitStatus) without structured results")
        }
        evidence += reports.paths.map { "logs/" + URL(fileURLWithPath: $0).lastPathComponent }
        if reports.counts.failed > 0 { return result(.failed, reports.counts, "a test failed") }
        if output.exitStatus != 0 {
            return result(.crashed, reports.counts, "swift test exited \(output.exitStatus) without a failing test")
        }
        return result(.passed, reports.counts, "every test passed")
    }
}

/// Runs `xcodebuild test-without-building` against the built `.xctestrun`, with the selector and marker directory in
/// every test target's environment. One worker: a destination runs one suite at a time.
public struct XcodeHarness<Executor: ProcessExecutor>: TestHarness {
    let executor: Executor
    let driver: BuildDriver
    let workspace: String
    let artifacts: String
    let logs: String
    public var maximumWorkers: Int { 1 }
    public var kind: String { "xcodebuild" }

    public init(executor: Executor, driver: BuildDriver, workspace: String, artifacts: String, logs: String) {
        self.executor = executor
        self.driver = driver
        self.workspace = workspace
        self.artifacts = artifacts
        self.logs = logs
    }

    public func run(_ request: TestRunRequest) async throws -> TestRunResult {
        let start = ContinuousClock.now
        func nanoseconds() -> Int64 {
            let duration = ContinuousClock.now - start
            return duration.components.seconds * 1_000_000_000 + duration.components.attoseconds / 1_000_000_000
        }
        let bundle = "\(logs)/\(request.name).xcresult"
        let xctestrun = try preparedTestRun(output: "\(logs)/\(request.name).xctestrun", request: request)
        let command = try driver.testCommand(
            workspace: workspace,
            artifacts: artifacts,
            result: bundle,
            xctestrun: xctestrun
        )
        let output = try await executor.execute(
            command,
            directory: workspace,
            environment: subjectEnvironment(request),
            timeout: request.deadline
        )
        try writeLog(output, path: "\(logs)/\(request.name).log")
        var evidence = ["logs/\(request.name).log"]
        func result(_ outcome: TestRunOutcome, _ counts: TestCounts?, _ reason: String) -> TestRunResult {
            TestRunResult(
                outcome: outcome,
                counts: counts,
                nanoseconds: nanoseconds(),
                evidence: evidence,
                reason: reason
            )
        }
        if output.timedOut { return result(.timedOut, nil, "xcodebuild exceeded \(request.deadline) s") }
        let summary = try await executor.execute(
            ToolCommand(
                executable: "/usr/bin/xcrun",
                arguments: ["xcresulttool", "get", "test-results", "summary", "--path", bundle, "--compact"]
            ),
            directory: workspace,
            environment: subjectEnvironment(nil),
            timeout: 60
        )
        guard summary.exitStatus == 0, !summary.truncated, let counts = try? TestEvidence.xcresult(summary.stdout)
        else {
            return result(.unusable, nil, "xcresult summary unavailable (xcodebuild exit \(output.exitStatus))")
        }
        try Data(summary.stdout).write(
            to: URL(fileURLWithPath: "\(logs)/\(request.name).summary.json"),
            options: .atomic
        )
        evidence += ["logs/\(request.name).summary.json", "logs/\(request.name).xcresult"]
        if counts.failed > 0 { return result(.failed, counts, "a test failed or its host crashed") }
        if output.exitStatus != 0 { return result(.unusable, counts, "xcodebuild exited \(output.exitStatus)") }
        return result(.passed, counts, "every test passed")
    }

    /// PropertyListSerialization supplies heterogeneous SDK data; the untyped boundary is contained here.
    /// Xcode-relative paths are absolutised before moving the plist outside Build/Products.
    private func preparedTestRun(output: String, request: TestRunRequest) throws -> String {
        let products = artifacts + "/DerivedData/Build/Products"
        let candidates = try FileManager.default.contentsOfDirectory(atPath: products)
            .filter { $0.hasSuffix(".xctestrun") }.sorted()
        guard candidates.count == 1, let file = candidates.first else {
            throw LitmusFailure("expected exactly one .xctestrun artifact; found \(candidates.count)")
        }
        let bytes = try BoundedFileReader.read(path: products + "/" + file, cap: 4 << 20)
        // SAFETY: the API is marked unsafe for its optional output pointer. We pass nil;
        // the input is owned bounded Data, and no caller-provided pointer is dereferenced or retained.
        let plist = try unsafe PropertyListSerialization.propertyList(from: Data(bytes), options: [], format: nil)
        let injected = subjectEnvironment(request)
        var patchedTargets = 0
        func patch(_ value: Any, depth: Int = 0) throws -> Any {
            guard depth <= 64 else { throw LitmusFailure("xctestrun nesting exceeds 64") }
            if let dictionary = value as? [String: Any] {
                var updated = try dictionary.mapValues { try patch($0, depth: depth + 1) }
                if dictionary["TestBundlePath"] != nil {
                    for key in ["EnvironmentVariables", "TestingEnvironmentVariables"] {
                        var environment = updated[key] as? [String: String] ?? [:]
                        for (name, value) in injected where name != "DEVELOPER_DIR" { environment[name] = value }
                        updated[key] = environment
                    }
                    patchedTargets += 1
                }
                return updated
            }
            if let array = value as? [Any] { return try array.map { try patch($0, depth: depth + 1) } }
            if let string = value as? String { return string.replacingOccurrences(of: "__TESTROOT__", with: products) }
            return value
        }
        let patched = try patch(plist)
        guard patchedTargets > 0 else { throw LitmusFailure("no supported test target in .xctestrun") }
        let data = try PropertyListSerialization.data(fromPropertyList: patched, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: output), options: .atomic)
        return output
    }
}
