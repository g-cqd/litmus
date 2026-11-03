internal import Foundation
internal import IndexStoreSupport

/// Bounded captured output; truncation is explicit and never used as test evidence.
public struct ProcessOutput: Sendable {
    public let exitStatus: Int32
    public let stdout: [UInt8]
    public let stderr: [UInt8]
    public let truncated: Bool
    public let timedOut: Bool
    /// The signal that ended the process, when one did (analyzerkit's `Result.terminationSignal`): a crash is told
    /// from a program exiting 134 by this, not by the status.
    public var terminationSignal: Int32? = nil
    /// Why the run's supervision stopped the process (a failing test seen, the memory limit), nil when it ended on its
    /// own.
    public var stopReason: String? = nil
    /// CPU of the process's session, sampled while it ran (nil when not sampled).
    public var cpuNanoseconds: UInt64? = nil
    /// The largest footprint of the process's session at one sample (nil when not sampled).
    public var peakFootprintBytes: UInt64? = nil
    /// Processes the process left behind, ended after it.
    public var reaped: [Int32] = []

    /// Carries raw process evidence; classification is a separate validated operation.
    public init(exitStatus: Int32, stdout: [UInt8], stderr: [UInt8], truncated: Bool, timedOut: Bool) {
        self.exitStatus = exitStatus; self.stdout = stdout; self.stderr = stderr
        self.truncated = truncated; self.timedOut = timedOut
    }

    /// Whether the memory limit stopped the process.
    public var exceededMemory: Bool { stopReason?.hasPrefix(Supervision.memoryLimitPrefix) == true }
}

/// How a command is watched beyond its deadline.
public struct Supervision: Sendable {
    /// Called beside the command from its start; calling `stop` with a reason ends it (its group, TERM then KILL) and
    /// records the reason in ``ProcessOutput/stopReason``. Cancelled when the command ends, and must then return.
    public var monitor: (@Sendable (_ stop: @escaping @Sendable (String) -> Void) async -> Void)? = nil
    /// Stop the command when its session's footprint passes this many bytes.
    public var memoryLimitBytes: UInt64? = nil
    /// Sample the session's CPU and memory at this interval.
    public var sampling: Duration? = nil
    /// Run at background priority: yields to everything else, and its timings stretch (2 to 15 times, measured).
    public var background = false

    public init() {}

    /// The prefix of the stop reason the memory limit gives (analyzerkit's wording).
    static let memoryLimitPrefix = "memory limit"
}

/// Injectable process boundary for deterministic execution tests.
public protocol ProcessExecutor: Sendable {
    func execute(
        _ command: ToolCommand,
        directory: String,
        environment: [String: String],
        timeout: Int,
        supervision: Supervision
    ) async throws -> ProcessOutput
}

extension ProcessExecutor {
    /// The command with no supervision beyond its deadline.
    public func execute(_ command: ToolCommand, directory: String, environment: [String: String], timeout: Int)
        async throws -> ProcessOutput
    {
        try await execute(
            command,
            directory: directory,
            environment: environment,
            timeout: timeout,
            supervision: .init()
        )
    }
}

/// The variable carrying a command's token, which `.xctestrun` environments pass on to simulator test hosts: whatever
/// holds it when the command ends is ended too.
let processTokenVariable = "LITMUS_PROCESS_TOKEN"

/// analyzerkit's `BoundedProcess`: a session per command, TERM then KILL on the deadline, output caps, a scrubbed
/// environment that keeps what selects a toolchain, and, once the command has ended, every process it left in its
/// session or that carries its token ended too. Deadlines run on the suspending clock: a
/// machine asleep does not time a test out.
public struct BoundedExecutor: ProcessExecutor {
    public init() {}

    public func execute(
        _ command: ToolCommand,
        directory: String,
        environment: [String: String],
        timeout: Int,
        supervision: Supervision
    ) async throws -> ProcessOutput {
        guard timeout > 0, timeout <= 86_400 else { throw LitmusFailure("timeout outside 1...86400 seconds") }
        let token = environment[processTokenVariable] ?? UUID().uuidString
        var options = BoundedProcess.Options()
        options.environmentToken = "\(processTokenVariable)=\(token)"
        options.memoryLimitBytes = supervision.memoryLimitBytes
        options.sampling = supervision.sampling
        options.priority = supervision.background ? .background : .inherited
        let env = BoundedProcess.environment(
            .toolchain,
            overrides: environment,
            source: ProcessInfo.processInfo.environment
        )
        var monitor: (@Sendable (BoundedProcess.ProcessControl) async -> Void)?
        if let watch = supervision.monitor {
            monitor = { @Sendable (control: BoundedProcess.ProcessControl) async -> Void in
                let stop: @Sendable (String) -> Void = { reason in control.stop(reason: reason) }
                await watch(stop)
            }
        }
        do {
            let result = try await BoundedProcess.run(
                command.executable,
                command.arguments,
                directory: directory,
                environment: env,
                timeout: .seconds(timeout),
                outputLimit: 4 << 20,
                options: options,
                monitor: monitor
            )
            var output = ProcessOutput(
                exitStatus: result.exitStatus,
                stdout: result.standardOutput,
                stderr: result.standardError,
                truncated: result.outputTruncated,
                timedOut: false
            )
            output.terminationSignal = result.terminationSignal
            output.stopReason = result.stopReason
            output.cpuNanoseconds = result.usage?.cpuNanoseconds
            output.peakFootprintBytes = result.usage?.peakFootprintBytes
            output.reaped = result.reaped
            return output
        } catch BoundedProcess.Failure.timedOut {
            return ProcessOutput(exitStatus: 124, stdout: [], stderr: [], truncated: false, timedOut: true)
        } catch BoundedProcess.Failure.cancelled {
            throw CancellationError()
        } catch BoundedProcess.Failure.notAbsolute(let path) {
            throw LitmusFailure("cannot launch \(path): not an absolute path")
        } catch BoundedProcess.Failure.launchFailed(let executable, let reason) {
            throw LitmusFailure("cannot launch \(executable): \(reason)")
        }
    }
}
