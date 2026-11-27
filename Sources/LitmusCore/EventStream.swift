internal import Foundation

/// Runs `makeCommand(streamPath)`, interposing a FIFO into `events` when `collectPerTestReach` is enabled.
func runEventStream<Executor: ProcessExecutor>(
    executor: Executor,
    request: TestRunRequest,
    stem: String,
    events: String,
    directory: String,
    baseEnvironment: [String: String],
    traceKey: String,
    deadline: Int,
    makeCommand: (String) -> ToolCommand
) async throws -> (output: ProcessOutput?, stoppedOnFailure: Bool) {
    guard request.collectPerTestReach else {
        return try await runWatching(
            executor,
            makeCommand(events),
            directory: directory,
            environment: baseEnvironment,
            deadline: deadline,
            events: events,
            failFast: request.failFast,
            supervision: request.supervision
        )
    }
    let fifo = "\(request.temporaryDirectory)/\(stem).fifo"
    var traceEnv = baseEnvironment
    traceEnv[traceKey] = fifo
    let command = makeCommand(fifo)
    return try await withEventFIFO(fifoPath: fifo, outputFile: events) {
        try await runWatching(
            executor,
            command,
            directory: directory,
            environment: traceEnv,
            deadline: deadline,
            events: events,
            failFast: request.failFast,
            supervision: request.supervision
        )
    }
}

/// Runs `body` with a named FIFO at `fifoPath` whose bytes are drained into `outputFile` on a detached thread, so
/// multiple `O_WRONLY | O_APPEND` writers in the child process (`swiftpm-testing-helper` / `SimulatorHelper` and the
/// schema runtime's `LITMUS_TEST_TRACE`) interleave complete lines in causal order without overwriting index 0.
func withEventFIFO<T: Sendable>(
    fifoPath: String,
    outputFile: String,
    body: () async throws -> T
) async throws -> T {
    try? FileManager.default.removeItem(atPath: fifoPath)
    let created = fifoPath.withCString { cPath in unsafe mkfifo(cPath, 0o600) }
    guard created == 0 else {
        throw LitmusFailure("mkfifo failed at \(fifoPath) (errno \(errno))")
    }
    defer { try? FileManager.default.removeItem(atPath: fifoPath) }
    FileManager.default.createFile(atPath: outputFile, contents: nil)
    let drainer = Task {
        await offPool {
            guard let reader = FileHandle(forReadingAtPath: fifoPath),
                let writer = FileHandle(forWritingAtPath: outputFile)
            else { return }
            defer {
                try? reader.close()
                try? writer.close()
            }
            while let chunk = try? reader.read(upToCount: 65_536), !chunk.isEmpty {
                try? writer.write(contentsOf: chunk)
            }
        }
    }
    do {
        let value = try await body()
        await drainer.value
        return value
    } catch {
        // Ensure a blocked reader on an unopened FIFO wakes up if `body` threw before spawning the child.
        let wake = fifoPath.withCString { cPath in unsafe open(cPath, O_WRONLY | O_NONBLOCK) }
        if wake >= 0 { close(wake) }
        await drainer.value
        throw error
    }
}

/// Runs a process while watching a Swift Testing event stream; on the first failing issue the run's monitor stops it
/// (analyzerkit's `BoundedProcess`: TERM then KILL to its group, its session cleaned up after).
func runWatching(
    _ executor: some ProcessExecutor,
    _ command: ToolCommand,
    directory: String,
    environment: [String: String],
    deadline: Int,
    events: String?,
    failFast: Bool,
    supervision base: Supervision = Supervision()
) async throws -> (output: ProcessOutput?, stoppedOnFailure: Bool) {
    var supervision = base
    if failFast, let events {
        supervision.monitor = StreamWatch.monitor(
            path: events,
            interval: .milliseconds(15),
            chunk: 1 << 20,
            bound: 4 << 20
        ) {
            pending in
            (try? TestEvidence.swiftTestingEvents(pending)).map {
                StreamWatch.Look(failed: $0.failed, consumed: $0.consumed)
            }
        }
    }
    let output = try await executor.execute(
        command,
        directory: directory,
        environment: environment,
        timeout: deadline,
        supervision: supervision
    )
    return (output, output.stopReason == failFastReason)
}
