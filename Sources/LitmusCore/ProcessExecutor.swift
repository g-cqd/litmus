internal import Foundation
internal import IndexStoreSupport

/// Bounded captured output; truncation is explicit and never used as test evidence.
public struct ProcessOutput: Sendable {
    public let exitStatus: Int32
    public let stdout: [UInt8]
    public let stderr: [UInt8]
    public let truncated: Bool
    public let timedOut: Bool
    /// Carries raw process evidence; classification is a separate validated operation.
    public init(exitStatus: Int32, stdout: [UInt8], stderr: [UInt8], truncated: Bool, timedOut: Bool) {
        self.exitStatus = exitStatus; self.stdout = stdout; self.stderr = stderr
        self.truncated = truncated; self.timedOut = timedOut
    }
}

/// Injectable process boundary for deterministic execution tests.
public protocol ProcessExecutor: Sendable {
    func execute(_ command: ToolCommand, directory: String, environment: [String: String], timeout: Int) async throws
        -> ProcessOutput
}

/// Uses analyzerkit's session-scoped subprocess runner, TERM/KILL escalation, output limits and scrubbed environment,
/// then kills any process that escaped the session's process group (`ProcessReaper`).
public struct BoundedExecutor: ProcessExecutor {
    public init() {}
    public func execute(_ command: ToolCommand, directory: String, environment: [String: String], timeout: Int)
        async throws -> ProcessOutput
    {
        guard timeout > 0, timeout <= 86_400 else { throw LitmusFailure("timeout outside 1...86400 seconds") }
        // The trampoline turns a launch failure into an exit status; a missing tool stays an error, as before.
        guard FileManager.default.isExecutableFile(atPath: command.executable) else {
            throw LitmusFailure("cannot launch \(command.executable): not an executable file")
        }
        var overrides = environment
        // Whatever the outcome, nothing of this command's session or carrying its token outlives it (`ProcessReaper`).
        let token = overrides[ProcessReaper.tokenVariable] ?? UUID().uuidString
        let sessionFile = FileManager.default.temporaryDirectory.appendingPathComponent(
            "litmus-session-\(UUID().uuidString)"
        ).path
        overrides[ProcessReaper.tokenVariable] = token
        overrides[ProcessReaper.sessionFileVariable] = sessionFile
        // One second of slack: start times are whole seconds.
        let started = Int(Date().timeIntervalSince1970) - 1
        defer {
            let recorded = try? String(contentsOfFile: sessionFile, encoding: .utf8)
            ProcessReaper.reap(session: recorded.flatMap { pid_t($0) }, token: token, since: started)
            try? FileManager.default.removeItem(atPath: sessionFile)
        }
        let (launched, env) = ProcessReaper.trampoline(
            command,
            environment: BoundedProcess.scrubbedEnvironment(
                overrides: overrides,
                source: ProcessInfo.processInfo.environment
            )
        )
        do {
            let result = try await BoundedProcess.run(
                launched.executable,
                launched.arguments,
                directory: directory,
                environment: env,
                timeout: .seconds(timeout),
                outputLimit: 4 << 20
            )
            return ProcessOutput(
                exitStatus: result.exitStatus,
                stdout: result.standardOutput,
                stderr: result.standardError,
                truncated: result.outputTruncated,
                timedOut: false
            )
        } catch BoundedProcess.Failure.timedOut {
            return ProcessOutput(exitStatus: 124, stdout: [], stderr: [], truncated: false, timedOut: true)
        } catch BoundedProcess.Failure.cancelled { throw CancellationError() }
    }
}
