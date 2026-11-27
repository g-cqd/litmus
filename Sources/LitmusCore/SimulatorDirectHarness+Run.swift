internal import AemiJSONCore
internal import Foundation
internal import SourceCorpus

extension SimulatorDirectHarness {
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

    func run(_ request: TestRunRequest, on udid: String) async throws -> TestRunResult {
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
    static func xctestEvents(_ path: String) -> [(name: String, status: String)]? {
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
