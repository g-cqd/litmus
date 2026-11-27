internal import Foundation
internal import SourceCorpus
internal import Synchronization

#if canImport(Darwin)
    internal import Darwin
#endif

private struct SharedWorkerCommand: Encodable {
    let configuration: SharedWorkerConfiguration
    let events: String
}

private struct SharedWorkerReady: Decodable {
    let ready: Bool
    let pid: Int?
}

private struct SharedWorkerReply: Decodable {
    let passed: Bool
}

/// Long-lived helper process serving narrowed Swift Testing runs over FIFO command/reply channels.
@safe final class SharedWorker: Sendable {
    struct Run: Sendable {
        let passed: Bool
        let scan: TestEvidence.EventScan?
        let nanoseconds: Int64
        var clean: Bool { passed && scan?.ended == true && scan?.failed == false }
    }

    private struct Mutable {
        var commands: Int32
        var helperPID: Int32?
        var processCached: Set<String> = []
        var suiteNanoseconds: Int64 = 0
        var mutants = 0
    }

    let module: String
    let generation: Int
    let page: SharedControlPage
    private let process: Process
    private let replies: FIFOLineReader
    private let mutable: Mutex<Mutable>

    var suiteNanoseconds: Int64 { mutable.withLock { $0.suiteNanoseconds } }
    var mutantsRun: Int { mutable.withLock { $0.mutants } }
    var cachedMutants: Set<String> { mutable.withLock { $0.processCached } }
    func isProcessCached(_ id: String) -> Bool { mutable.withLock { $0.processCached.contains(id) } }
    func recordMutantAttempt() { mutable.withLock { $0.mutants += 1 } }

    static func spawn<Backend: SharedProcessBackend>(
        bundle: SharedBundle,
        generation: Int,
        slots: [String],
        helper: String,
        scratch: String,
        token: String,
        direct: Backend,
        request: TestRunRequest
    ) async throws -> SharedWorker? {
        let directory = scratch + "/worker-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: directory + "/tmp", withIntermediateDirectories: true)
        let page = try SharedControlPage(path: directory + "/page", slots: slots)
        page.countsEvaluations = true
        let name = "shared-\(bundle.module)-\(directory.suffix(8))"
        let commandsPath = directory + "/commands"
        let repliesPath = directory + "/replies"
        let command = await direct.serveCommand(
            bundle: bundle,
            helper: helper,
            arguments: [bundle.binary, "\(direct.logs)/\(name).out.log", commandsPath, repliesPath],
            environment: [
                "TMPDIR": directory + "/tmp",
                ActivationEnvironment.key(ActivationEnvironment.sharedControlPage, token: token): page.path,
            ]
        )
        guard
            let worker = try SharedWorker(
                module: bundle.module,
                generation: generation,
                command: command,
                commandsPath: commandsPath,
                repliesPath: repliesPath,
                processToken: directory,
                errorLog: "\(direct.logs)/\(name).err.log",
                page: page
            )
        else { return nil }
        guard await worker.waitReady(timeout: 120) else {
            worker.terminate()
            return nil
        }
        let launch = page.evaluations()
        var passes: [[String: UInt64]] = []
        let classifyConfig = SharedWorkerConfiguration(
            filter: nil,
            skip: request.skipSwiftTesting.isEmpty ? nil : request.skipSwiftTesting.map(filterPattern(for:)),
            experimentalMaximumParallelizationWidth: nil
        )
        for pass in 1...2 {
            let run = try await worker.run(
                classifyConfig,
                events: "\(direct.logs)/\(name)-classify-\(pass).events.jsonl",
                timeout: request.deadline
            )
            guard let run, run.clean else {
                worker.terminate()
                return nil
            }
            worker.mutable.withLock { $0.suiteNanoseconds = max($0.suiteNanoseconds, run.nanoseconds) }
            passes.append(page.evaluations())
        }
        page.countsEvaluations = false
        let cached = Set(
            slots.filter { id in
                let atLaunch = launch[id] ?? 0
                let first = (passes[0][id] ?? 0) &- atLaunch
                let second = (passes[1][id] ?? 0) &- (passes[0][id] ?? 0)
                return atLaunch > 0 || first != second
            }
        )
        worker.mutable.withLock { $0.processCached = cached }
        return worker
    }

    private init?(
        module: String,
        generation: Int,
        command: ServeCommand,
        commandsPath: String,
        repliesPath: String,
        processToken: String,
        errorLog: String,
        page: SharedControlPage
    ) throws {
        self.module = module
        self.generation = generation
        self.page = page
        for path in [commandsPath, repliesPath] {
            guard unsafe mkfifo(path, 0o600) == 0 else { throw LitmusFailure("mkfifo \(path): errno \(errno)") }
        }
        // Open both FIFOs O_RDWR before spawning so neither open returns ENXIO or spurious EOF before the child opens
        // its ends; child exit wakes `replies` immediately via `terminationHandler`.
        let writer = unsafe open(commandsPath, O_RDWR)
        let reader = writer >= 0 ? unsafe open(repliesPath, O_RDWR | O_NONBLOCK) : -1
        guard writer >= 0, reader >= 0 else {
            if writer >= 0 { close(writer) }
            if reader >= 0 { close(reader) }
            return nil
        }
        _ = fcntl(writer, F_SETFD, FD_CLOEXEC)
        _ = fcntl(reader, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writer, F_SETNOSIGPIPE, 1)

        let proc = Process()
        guard let lineReader = FIFOLineReader(descriptor: reader) else {
            close(writer)
            return nil
        }
        proc.executableURL = URL(fileURLWithPath: command.executable)
        proc.arguments = command.arguments
        var environment = command.environment
        environment[processTokenVariable] = processToken
        proc.environment = environment
        proc.currentDirectoryURL = URL(fileURLWithPath: command.directory)
        proc.standardInput = FileHandle.nullDevice
        FileManager.default.createFile(atPath: errorLog, contents: nil)
        let log = FileHandle(forWritingAtPath: errorLog)
        proc.standardOutput = log
        proc.standardError = log
        proc.terminationHandler = { _ in lineReader.signalPeerExited() }
        do {
            try proc.run()
        } catch {
            close(writer)
            lineReader.close()
            return nil
        }
        self.process = proc
        self.replies = lineReader
        self.mutable = Mutex(Mutable(commands: writer))
    }

    private func waitReady(timeout: Int) async -> Bool {
        guard case .line(let line) = await replies.next(timeout: timeout),
            let ready = try? JSONDecoder().decode(SharedWorkerReady.self, from: line),
            ready.ready
        else { return false }
        let pid = ready.pid.flatMap(Int32.init(exactly:))
        mutable.withLock { $0.helperPID = pid }
        return true
    }

    func run(_ configuration: SharedWorkerConfiguration, events: String, timeout: Int) async throws -> Run? {
        let start = ContinuousClock.now
        let encoded = try JSONEncoder().encode(SharedWorkerCommand(configuration: configuration, events: events))
        let payload = encoded + Data([0x0A])
        let wrote = mutable.withLock { m -> Bool in
            guard m.commands >= 0 else { return false }
            var offset = 0
            while offset < payload.count {
                // SAFETY: `payload` is owned for this scope and `offset < payload.count`.
                let count = unsafe payload[offset...].withUnsafeBytes {
                    unsafe Darwin.write(m.commands, $0.baseAddress, $0.count)
                }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard wrote else { return nil }
        guard case .line(let line) = await replies.next(timeout: timeout),
            let reply = try? JSONDecoder().decode(SharedWorkerReply.self, from: line)
        else {
            terminate()
            return nil
        }
        let nanos = nanoseconds(since: start)
        let scan = try? TestEvidence.swiftTestingEvents(BoundedFileReader.read(path: events, cap: 64 << 20))
        return Run(passed: reply.passed, scan: scan, nanoseconds: nanos)
    }

    func terminate() {
        let pid = mutable.withLock { m -> Int32? in
            if m.commands >= 0 {
                Darwin.close(m.commands)
                m.commands = -1
            }
            return m.helperPID
        }
        if let pid, pid > 1 { kill(pid, SIGKILL) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        replies.close()
        process.waitUntilExit()
    }
}
