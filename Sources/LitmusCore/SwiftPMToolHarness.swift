internal import Foundation

/// Runs `swift test` per execution: the conservative fallback when bundles cannot be run directly. One worker, because
/// SwiftPM locks the scratch directory.
public struct SwiftPMToolHarness<Executor: ProcessExecutor>: TestHarness {
    let executor: Executor
    let driver: BuildDriver
    let workspace: String
    let artifacts: String
    let logs: String
    public var capabilities: HarnessCapabilities { HarnessCapabilities() }
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
            directory: driver.executionDirectory(workspace: workspace),
            environment: subjectEnvironment(request),
            timeout: request.deadline,
            supervision: request.supervision
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
        if output.exceededMemory { return result(.crashed, nil, abnormalEnd(output, "swift test")) }
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
