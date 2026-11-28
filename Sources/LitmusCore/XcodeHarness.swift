internal import Foundation
internal import SourceCorpus

/// Runs `xcodebuild test-without-building` against the built `.xctestrun`, with the selector and marker directory in
/// every test target's environment. One worker: a destination runs one suite at a time.
public struct XcodeHarness<Executor: ProcessExecutor>: TestHarness {
    let executor: Executor
    let driver: BuildDriver
    let workspace: String
    let artifacts: String
    let logs: String
    /// Simulators Litmus made, one worker each; nil runs on the driver's one destination.
    let fleet: SimulatorFleet?
    /// Keep every run's result bundle (hundreds of MiB each on a real app); the summary is kept either way.
    let keepResultBundles: Bool
    public var kind: String { "xcodebuild" }
    /// `-only-testing:<target>`, with counts per test bundle from the result bundle.
    public var capabilities: HarnessCapabilities {
        HarnessCapabilities(maximumWorkers: fleet?.count ?? 1, selectsModules: true)
    }

    public init(
        executor: Executor,
        driver: BuildDriver,
        workspace: String,
        artifacts: String,
        logs: String,
        fleet: SimulatorFleet? = nil,
        keepResultBundles: Bool = false
    ) {
        self.executor = executor
        self.driver = driver
        self.workspace = workspace
        self.artifacts = artifacts
        self.logs = logs
        self.fleet = fleet
        self.keepResultBundles = keepResultBundles
    }

    public func run(_ request: TestRunRequest) async throws -> TestRunResult {
        guard let fleet, fleet.count > 1 else { return try await run(request, on: nil) }
        return try await fleet.withDevice { device in
            let result = try await self.run(request, on: device)
            return (result, result.outcome == .crashed || result.outcome == .timedOut)
        }
    }

    /// One run, on the driver's destination or on a worker's own simulator and DerivedData.
    private func run(_ request: TestRunRequest, on device: PoolDevice?) async throws -> TestRunResult {
        let start = ContinuousClock.now
        func elapsedNanoseconds() -> Int64 { nanoseconds(since: start) }
        let bundle = "\(logs)/\(request.name).xcresult"
        // Workers share the build products: no schema is built while tests run, and a test run only reads them. Each
        // worker writes its own DerivedData, so concurrent runs never share xcodebuild's state.
        let products = artifacts + "/DerivedData/Build/Products"
        var derivedData: String?
        if let device {
            derivedData = device.directory + "/DerivedData"
            try FileManager.default.createDirectory(atPath: derivedData ?? "", withIntermediateDirectories: true)
        }
        let xctestrun = try preparedTestRun(
            output: "\(logs)/\(request.name).xctestrun",
            request: request,
            products: products
        )
        // With fail-fast, Xcode's event stream shows the first failed test, and the run stops there.
        let stream = request.failFast ? "\(logs)/\(request.name).stream.jsonl" : nil
        if let stream { _ = FileManager.default.createFile(atPath: stream, contents: nil) }
        let command = try driver.testCommand(
            workspace: workspace,
            artifacts: artifacts,
            result: bundle,
            xctestrun: xctestrun,
            onlyTesting: request.onlyModules.map { Array($0) },
            skipTesting: Array(request.skipModules),
            resultStream: stream,
            destination: device?.destination,
            derivedData: derivedData
        )
        var supervision = Self.supervision(request.supervision)
        if let stream { supervision.monitor = XcodeResultStream.monitor(path: stream) }
        // The simulator's test host is outside `xcodebuild`'s session, and is ended after the run through the token its
        // `.xctestrun` environment carries.
        let output = try await executor.execute(
            command,
            directory: driver.executionDirectory(workspace: workspace),
            environment: subjectEnvironment(request),
            timeout: request.deadline,
            supervision: supervision
        )
        try writeLog(output, path: "\(logs)/\(request.name).log")
        var evidence = ["logs/\(request.name).log"]
        func discardBundle() { if !keepResultBundles { try? FileManager.default.removeItem(atPath: bundle) } }
        func result(_ outcome: TestRunOutcome, _ counts: TestCounts?, _ reason: String) -> TestRunResult {
            TestRunResult(
                outcome: outcome,
                counts: counts,
                nanoseconds: elapsedNanoseconds(),
                evidence: evidence,
                reason: reason
            )
        }
        if output.stopReason == failFastReason, let stream {
            // Stopped at the first failed test or host crash: the bundle is incomplete, and the stream names why.
            let scanned = (try? BoundedFileReader.read(path: stream, cap: 64 << 20)).map(XcodeResultStream.scan)
            evidence.append("logs/\(request.name).stream.jsonl")
            discardBundle()
            if scanned?.crashed == true {
                return result(.crashed, nil, hostCrashReason)
            }
            var stopped = result(.failed, nil, "an Xcode test failed (stopped early)")
            stopped.failingTests = scanned?.failedTests ?? []
            return stopped
        }
        if let stream { try? FileManager.default.removeItem(atPath: stream) }
        if output.timedOut {
            discardBundle()
            return result(.timedOut, nil, "xcodebuild exceeded \(request.deadline) s")
        }
        let summary = try await resultTool("summary", bundle: bundle)
        guard summary.exitStatus == 0, !summary.truncated, let counts = try? TestEvidence.xcresult(summary.stdout)
        else {
            // Kept whatever the options say: it is what a person debugging an unusable run looks at.
            evidence.append("logs/\(request.name).xcresult")
            let stopped = output.stopReason.map { ", stopped: \($0)" } ?? ""
            return result(
                .unusable,
                nil,
                "xcresult summary unavailable (xcodebuild exit \(output.exitStatus)\(stopped))"
            )
        }
        try Data(summary.stdout).write(
            to: URL(fileURLWithPath: "\(logs)/\(request.name).summary.json"),
            options: .atomic
        )
        evidence += ["logs/\(request.name).summary.json"]
        if keepResultBundles { evidence.append("logs/\(request.name).xcresult") }
        // Counts per test bundle, what `-only-testing` selections are checked against; left out unless they add up
        // to the summary's.
        let tests = try await resultTool("tests", bundle: bundle)
        var modules: [String: TestCounts] = [:]
        if tests.exitStatus == 0, !tests.truncated, let parsed = TestEvidence.xcresultModules(tests.stdout) {
            let sum = parsed.values.reduce(into: (0, 0, 0)) {
                $0 = ($0.0 + $1.passed, $0.1 + $1.failed, $0.2 + $1.skipped)
            }
            if sum == (counts.passed, counts.failed, counts.skipped) { modules = parsed }
        }
        discardBundle()
        func finished(_ outcome: TestRunOutcome, _ reason: String) -> TestRunResult {
            var finished = result(outcome, counts, reason)
            finished.moduleCounts = modules
            if outcome != .passed {
                // xcodebuild runs every bundle: the summary's first failing target, else a bundle with failures.
                finished.failedModule =
                    TestEvidence.xcresultFailedTargets(summary.stdout).first
                    ?? modules.filter { $0.value.failed > 0 }.keys.sorted().first
            }
            return finished
        }
        if counts.failed > 0 {
            // A crashed runner or host fails every test it was running: a crash, which is rerun as one.
            return TestEvidence.xcresultCrashed(summary.stdout)
                ? finished(.crashed, "the test runner or host crashed") : finished(.failed, "a test failed")
        }
        if output.exitStatus != 0 { return finished(.unusable, "xcodebuild exited \(output.exitStatus)") }
        return finished(.passed, "every test passed")
    }

    /// PropertyListSerialization supplies heterogeneous SDK data; the untyped boundary is contained here.
    /// Xcode-relative paths are absolutised before moving the plist outside Build/Products.
    /// `base` without its memory limit, which covers only `xcodebuild`'s session: the test hosts run in the simulator,
    /// outside it, so the limit cannot catch a mutant's runaway allocation and only stops `xcodebuild` as its own
    /// memory grows with the suite's output (an app of fourteen bundles: 4 GiB after four).
    static func supervision(_ base: Supervision) -> Supervision {
        var supervision = base
        supervision.memoryLimitBytes = nil
        return supervision
    }

    /// `xcresulttool get test-results <report>` of `bundle`, compact JSON.
    func resultTool(_ report: String, bundle: String) async throws -> ProcessOutput {
        try await executor.execute(
            ToolCommand(
                executable: "/usr/bin/xcrun",
                arguments: ["xcresulttool", "get", "test-results", report, "--path", bundle, "--compact"]
            ),
            directory: driver.executionDirectory(workspace: workspace),
            environment: subjectEnvironment(nil),
            timeout: 60
        )
    }

    private func preparedTestRun(output: String, request: TestRunRequest, products: String) throws -> String {
        let patched = try testRunPlist(request: request, products: products)
        let data = try PropertyListSerialization.data(fromPropertyList: patched, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: output), options: .atomic)
        return output
    }

    /// The built `.xctestrun`, with `request`'s environment in every test target.
    func testRunPlist(request: TestRunRequest, products: String) throws -> Any {
        let candidates = try FileManager.default.contentsOfDirectory(atPath: products)
            .filter { $0.hasSuffix(".xctestrun") }.sorted()
        guard candidates.count == 1, let file = candidates.first else {
            throw LitmusFailure("expected exactly one .xctestrun artifact; found \(candidates.count)")
        }
        let bytes = try BoundedFileReader.read(path: products + "/" + file, cap: 4 << 20)
        try XcodeTestConfiguration.validateTestRun(bytes, path: products + "/" + file)
        // SAFETY: the API is marked unsafe for its optional output pointer. We pass nil;
        // the input is owned bounded Data, and no caller-provided pointer is dereferenced or retained.
        let plist = try unsafe PropertyListSerialization.propertyList(from: Data(bytes), options: [], format: nil)
        let injected = subjectEnvironment(request)
        let (patched, patchedTargets) = try Self.patchTestRunPlist(plist, injected: injected, products: products)
        guard patchedTargets > 0 else {
            throw LitmusFailure(
                "zero supported test targets in \(products)/\(file); scheme \(driver.scheme ?? "unknown"). Check the selected test plan and containerPath; for nested packages use --package-path."
            )
        }
        return patched
    }

    /// Rewrites `EnvironmentVariables`, `TestingEnvironmentVariables`, and (for UI test bundles)
    /// `UITargetAppEnvironmentVariables` so XCUITest launches `XCUIApplication` with Litmus's active mutant and
    /// coverage directory automatically, with zero app or UI test setup.
    static func patchTestRunPlist(
        _ plist: Any,
        injected: [String: String],
        products: String
    ) throws -> (Any, Int) {
        var patchedTargets = 0
        func patch(_ value: Any, depth: Int = 0) throws -> Any {
            guard depth <= 64 else { throw LitmusFailure("xctestrun nesting exceeds 64") }
            if let dictionary = value as? [String: Any] {
                var updated = try dictionary.mapValues { try patch($0, depth: depth + 1) }
                if dictionary["TestBundlePath"] != nil {
                    var keys = ["EnvironmentVariables", "TestingEnvironmentVariables"]
                    if (dictionary["IsUITestBundle"] as? Bool) == true || dictionary["UITargetAppPath"] != nil {
                        keys.append("UITargetAppEnvironmentVariables")
                    }
                    for key in keys {
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
        return (try patch(plist), patchedTargets)
    }
}
