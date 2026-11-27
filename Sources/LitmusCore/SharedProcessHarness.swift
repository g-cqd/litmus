internal import Foundation
internal import SourceCorpus

#if canImport(Darwin)
    internal import Darwin
#endif

/// A test bundle a shared-process helper can serve.
struct SharedBundle: Sendable, Equatable {
    let module: String
    /// The binary the helper loads.
    let binary: String
    /// Whether it holds Swift Testing tests (unknown for a simulator bundle: assumed, a filter then selects nothing).
    let hasSwiftTesting: Bool
}

/// How to start a helper's serve loop: the program, its arguments and environment, and its directory.
struct ServeCommand: Sendable {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    let directory: String
}

/// A harness whose bundles a shared-process helper can serve: the macOS SwiftPM one and the simulator one.
protocol SharedProcessBackend: TestHarness {
    var sharedBundles: [SharedBundle] { get }
    var logs: String { get }
    /// The command that starts `helper`'s serve loop on `bundle` with `arguments` (the serve arguments after the
    /// helper), the subject's environment plus `environment` (the control page, the worker's TMPDIR).
    func serveCommand(bundle: SharedBundle, helper: String, arguments: [String], environment: [String: String]) async
        -> ServeCommand
}

/// What the run session asks of a shared-process harness, whatever its backend.
protocol SharedProcessControl: AnyObject, Sendable {
    var mode: SharedProcessMode { get }
    var bundleCount: Int { get }
    var statistics: SharedProcessStatistics { get }
    func prepare(batch: [Mutation])
    func decide(covered: Int, workers: Int, suiteNanoseconds: Int64, spawnNanoseconds: Int64) -> String?
    func shutdown()
}

/// What a shared-process harness decided where, for the run's notes.
public struct SharedProcessStatistics: Sendable, Equatable {
    public var sharedKills = 0
    public var sharedPasses = 0
    public var freshRuns = 0
    public var workersStarted = 0
    public var workersRetired = 0
    public var processCached: Set<String> = []
    /// Batches `auto` engaged, and those it left to fresh processes.
    public var batchesEngaged = 0
    public var batchesDeclined = 0
}

/// Shared-process execution (docs/design/shared-process.md): a mutant's narrowed Swift Testing run goes to a helper
/// process that already loaded the test bundle, on macOS or on a simulator, and the shared control page switches the
/// mutant on.
///
/// Only kills are decided there, and only when the mutant's switch was evaluated (`activeHits > 0`) and the failing
/// tests pass again unmutated in the same process. Everything else runs in a fresh process through the direct
/// harness: XCTest, whole-suite runs, controls, survivors (always confirmed fresh), mutants the worker classified as
/// process-cached (evaluated while loading, or a different number of times in two unmutated passes), crashes,
/// timeouts and any doubt about the worker's state, after which the worker is replaced.
final class SharedProcessHarness<Backend: SharedProcessBackend>: TestHarness, SharedProcessControl,
    @unchecked Sendable
{
    let direct: Backend
    /// Builds (or finds in the cache) the helper program; called once, when the first worker starts.
    let buildHelper: @Sendable () async throws -> String
    let scratch: String
    let token: String
    let mode: SharedProcessMode
    public var capabilities: HarnessCapabilities { direct.capabilities }
    /// `swiftpm-shared` or `simulator-shared` when always on; with `auto`, the direct harness's kind (a note says which
    /// batches used workers).
    public var kind: String {
        guard mode == .on else { return direct.kind }
        return (direct.kind.hasSuffix("-direct") ? String(direct.kind.dropLast("-direct".count)) : direct.kind)
            + "-shared"
    }

    private let lock = NSLock()
    private var generation = 0
    /// The current batch's mutants, by slot.
    private var slots: [String] = []
    private var idle: [String: [Worker]] = [:]
    /// Modules whose worker could not be classified in this generation: fresh processes only.
    private var unshareable: Set<String> = []
    private var counts = SharedProcessStatistics()
    /// Whether this batch's narrowed runs go to workers: always with `on`, per batch with `auto` (``decide(covered:workers:suiteNanoseconds:spawnNanoseconds:)``).
    private var engaged: Bool
    /// The built helper, or why it could not be built (`auto` then stays off for the run).
    private var helperPath: Result<String, LitmusFailure>?

    init(
        direct: Backend,
        helper: @escaping @Sendable () async throws -> String,
        scratch: String,
        token: String,
        mode: SharedProcessMode = .on
    ) {
        self.direct = direct
        self.buildHelper = helper
        self.scratch = scratch
        self.token = token
        self.mode = mode
        self.engaged = mode == .on
    }

    /// The process start below which shared workers never pay: on macOS (0.07–0.17 s per SwiftPM bundle on the
    /// benchmark's packages) `on` was as slow or up to twice as slow as isolated runs, the classification passes,
    /// control passes and survivor checks costing more than the starts saved (docs/design/shared-process.md).
    static var minimumSpawnNanoseconds: Int64 { 250_000_000 }

    /// Whether shared workers pay for a batch (design note, decision 9): at least 8 covered mutants, a process start of
    /// at least ``minimumSpawnNanoseconds``, and the starts saved exceeding what the workers cost, each a start and two
    /// unmutated passes over its bundle: `covered × spawn > workers × (2 × suite + spawn)`.
    static func breaksEven(covered: Int, workers: Int, suiteNanoseconds: Int64, spawnNanoseconds: Int64) -> Bool {
        guard covered >= 8, spawnNanoseconds >= minimumSpawnNanoseconds else { return false }
        let saved = Double(covered) * Double(spawnNanoseconds)
        let cost = Double(max(1, workers)) * (2 * Double(suiteNanoseconds) + Double(spawnNanoseconds))
        return saved > cost
    }

    /// With `auto`, engages workers for the batch about to run when they pay; returns the note that says why. `on` and
    /// `off` decide nothing. Process start and suite times come from the batch's inactive control run, per bundle.
    func decide(covered: Int, workers: Int, suiteNanoseconds: Int64, spawnNanoseconds: Int64) -> String? {
        guard mode == .auto else { return nil }
        let pays = Self.breaksEven(
            covered: covered,
            workers: workers,
            suiteNanoseconds: suiteNanoseconds,
            spawnNanoseconds: spawnNanoseconds
        )
        let available = lock.withLock {
            let available = (try? helperPath?.get()) != nil || helperPath == nil
            engaged = pays && available
            if engaged { counts.batchesEngaged += 1 } else { counts.batchesDeclined += 1 }
            return available
        }
        guard available else { return nil }
        let seconds = { (nanos: Int64) in (Double(nanos) / 1e7).rounded() / 100 }
        return
            "shared process (auto): \(pays ? "on" : "off") for \(covered) covered mutant(s) and \(workers) worker(s); "
            + "process start ~\(seconds(spawnNanoseconds)) s, bundle suite ~\(seconds(suiteNanoseconds)) s per bundle"
    }

    /// The helper's path, built on first use. With `auto`, a helper that does not build turns shared workers off for
    /// the rest of the run (returns nil); with `on`, it is an error.
    private func helper() async throws -> String? {
        if let known = lock.withLock({ helperPath }) {
            switch known {
            case .success(let path): return path
            case .failure(let failure): if mode == .on { throw failure } else { return nil }
            }
        }
        do {
            let path = try await buildHelper()
            lock.withLock { helperPath = .success(path) }
            return path
        } catch {
            let failure = LitmusFailure("the shared-process helper is unavailable: \(error)")
            lock.withLock {
                helperPath = .failure(failure)
                if mode == .auto { engaged = false }
            }
            if mode == .on { throw failure }
            return nil
        }
    }

    deinit { shutdown() }

    var statistics: SharedProcessStatistics { lock.withLock { counts } }
    var bundleCount: Int { direct.sharedBundles.count }

    /// A new schema batch is built: workers of the previous build are ended, and slots follow `batch`.
    func prepare(batch: [Mutation]) {
        let retired: [Worker] = lock.withLock {
            generation += 1
            slots = SharedControlLayout.slots(for: batch).sorted { $0.value < $1.value }.map(\.key)
            unshareable = []
            defer { idle = [:] }
            return idle.values.flatMap { $0 }
        }
        for worker in retired { worker.terminate() }
    }

    /// Ends every idle worker.
    func shutdown() {
        let retired: [Worker] = lock.withLock {
            defer { idle = [:] }
            return idle.values.flatMap { $0 }
        }
        for worker in retired { worker.terminate() }
    }

    public func run(_ request: TestRunRequest) async throws -> TestRunResult {
        let start = ContinuousClock.now
        let isEngaged = lock.withLock { engaged }
        func fresh() async throws -> TestRunResult {
            if isEngaged { lock.withLock { counts.freshRuns += 1 } }
            return try await direct.run(request)
        }
        guard isEngaged else { return try await fresh() }
        guard !request.activeID.isEmpty, !request.alone, let only = request.onlySwiftTesting, !only.isEmpty,
            !request.collectPerTestReach, request.repetitions == nil,
            lock.withLock({ slots.contains(request.activeID) })
        else { return try await fresh() }
        let targets = direct.sharedBundles.filter { bundle in
            only.contains { $0.hasPrefix(bundle.module + ".") }
                && request.onlyModules.map { $0.contains(bundle.module) } ?? true
                && !request.skipModules.contains(bundle.module)
        }
        guard !targets.isEmpty, targets.allSatisfy(\.hasSwiftTesting) else { return try await fresh() }
        var passed = 0, skipped = 0
        var evidence: [String] = []
        var scans: [TestEvidence.EventScan] = []
        var wasHit = false
        for bundle in targets {
            guard let worker = try await checkout(bundle, request: request) else { return try await fresh() }
            if worker.processCached.contains(request.activeID) {
                checkin(worker)
                return try await fresh()
            }
            worker.mutants += 1
            switch try await runShared(bundle, worker: worker, request: request, start: start) {
            case .killed(let result):
                checkin(worker)
                lock.withLock { counts.sharedKills += 1 }
                return result
            case .passed(let scan, let bundleEvidence, let hit):
                checkin(worker)
                passed += scan.counts.passed
                skipped += scan.counts.skipped
                evidence += bundleEvidence
                scans.append(scan)
                wasHit = wasHit || hit
            case .doubt:
                retire(worker)
                return try await fresh()
            }
        }
        // Without the full-module recheck this run would decide a survivor: run fresh instead.
        guard request.rechecksNarrowedSurvivors else { return try await fresh() }
        if wasHit {
            FileManager.default.createFile(atPath: request.coverageDirectory + "/" + request.activeID, contents: nil)
        }
        lock.withLock { counts.sharedPasses += 1 }
        var result = TestRunResult(
            outcome: .passed,
            counts: TestCounts(passed: passed, failed: 0, skipped: skipped),
            nanoseconds: nanoseconds(since: start),
            evidence: evidence,
            reason: "passed in shared worker (rechecked against the full modules)"
        )
        result.ranInSharedWorker = true
        for scan in scans { result.absorb(scan) }
        return result
    }

    private enum SharedOutcome {
        case killed(TestRunResult)
        case passed(TestEvidence.EventScan, [String], Bool)
        /// The worker's state or the run is in doubt: replace the worker and decide in a fresh process.
        case doubt
    }

    private func runShared(
        _ bundle: SharedBundle,
        worker: Worker,
        request: TestRunRequest,
        start: ContinuousClock.Instant
    ) async throws -> SharedOutcome {
        let remaining = max(1, request.deadline - Int(nanoseconds(since: start) / 1_000_000_000))
        // The worker already loaded the bundle: its unmutated pass took `suiteNanoseconds`, not a fresh process's
        // static deadline. A mutant that hangs here fails in seconds and gets its full deadline in a fresh process.
        let runTimeout = min(remaining, max(3, 4 * Int(worker.suiteNanoseconds / 1_000_000_000) + 2))
        let tests = (request.onlySwiftTesting ?? []).filter { $0.hasPrefix(bundle.module + ".") }
        let stem = "\(request.name)-\(bundle.module)-shared"
        /// The mutant's tests, once, with whatever the page holds; events in `logs/<stem><suffix>.events.jsonl`.
        func pass(_ suffix: String) async throws -> Worker.Run? {
            try await worker.run(
                Self.configuration(only: tests, skip: request.skipSwiftTesting, width: request.parallelizationWidth),
                events: "\(direct.logs)/\(stem)\(suffix).events.jsonl",
                timeout: runTimeout
            )
        }
        try worker.page.activate(request.activeID)
        let active = try await pass("")
        let hits = worker.page.activeHits
        try worker.page.activate(nil)
        guard let active, let scan = active.scan, scan.ended else { return .doubt }
        if !scan.failed && active.passed {
            // The mutant survived here; its run may still have left state behind. Look before the next mutant.
            guard try await pass("-after")?.clean == true else { return .doubt }
            return .passed(scan, ["logs/\(stem).events.jsonl", "logs/\(stem)-after.events.jsonl"], hits > 0)
        }
        let failing = scan.failedTests.map(testName).sorted()
        guard hits > 0, !failing.isEmpty else { return .doubt }
        // The kill stands only if the mutant's tests (the failing ones among them) pass again unmutated in this
        // process: the failure was the mutant's, and what it left behind does not fail them for the next mutant.
        guard try await pass("-control")?.clean == true else { return .doubt }
        FileManager.default.createFile(atPath: request.coverageDirectory + "/" + request.activeID, contents: nil)
        var result = TestRunResult(
            outcome: .failed,
            counts: nil,
            nanoseconds: nanoseconds(since: start),
            evidence: ["logs/\(stem).events.jsonl", "logs/\(stem)-control.events.jsonl"],
            reason: "Swift Testing recorded a failing issue (shared process)"
        )
        result.failingTests = failing
        result.failedModule = bundle.module
        result.ranInSharedWorker = true
        result.absorb(scan)
        return .killed(result)
    }

    /// Swift Testing's configuration for one run: these tests, without the flaky ones.
    static func configuration(only: [String], skip: [String], width: Int?) -> [String: Any] {
        var object: [String: Any] = ["filter": only.map(filterPattern(for:))]
        if !skip.isEmpty { object["skip"] = skip.map(filterPattern(for:)) }
        if let width { object["experimentalMaximumParallelizationWidth"] = width }
        return object
    }

    // MARK: Workers

    private func checkout(_ bundle: SharedBundle, request: TestRunRequest) async throws
        -> Worker?
    {
        let (reused, current, batch, refused): (Worker?, Int, [String], Bool) = lock.withLock {
            (idle[bundle.module]?.popLast(), generation, slots, unshareable.contains(bundle.module))
        }
        if let reused { return reused }
        guard !refused else { return nil }
        let worker = try await spawn(bundle, generation: current, slots: batch, request: request)
        lock.withLock {
            if let worker {
                counts.workersStarted += 1
                counts.processCached.formUnion(worker.processCached)
            } else if generation == current {
                unshareable.insert(bundle.module)
            }
        }
        return worker
    }

    /// The most mutants one worker runs: what a mutant leaves behind that no check sees lives at most this long.
    static var mutantsPerWorker: Int { 32 }

    private func checkin(_ worker: Worker) {
        let keep = lock.withLock {
            guard worker.generation == generation, worker.mutants < Self.mutantsPerWorker else { return false }
            idle[worker.module, default: []].append(worker)
            return true
        }
        if !keep { worker.terminate() }
    }

    private func retire(_ worker: Worker) {
        lock.withLock { counts.workersRetired += 1 }
        worker.terminate()
    }

    /// Starts a helper on `bundle` and classifies the batch's switches: evaluated while loading, or a different
    /// number of times in two unmutated passes over the bundle, is process-cached. Nil when the helper does not start
    /// or an unmutated pass does not pass.
    private func spawn(
        _ bundle: SharedBundle,
        generation: Int,
        slots: [String],
        request: TestRunRequest
    ) async throws -> Worker? {
        guard let helper = try await helper() else { return nil }
        let directory = scratch + "/worker-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: directory + "/tmp", withIntermediateDirectories: true)
        let page = try SharedControlPage(path: directory + "/page", slots: slots)
        page.countsEvaluations = true
        let name = "shared-\(bundle.module)-\(directory.suffix(8))"
        let commands = directory + "/commands", replies = directory + "/replies"
        let command = await direct.serveCommand(
            bundle: bundle,
            helper: helper,
            arguments: [bundle.binary, "\(direct.logs)/\(name).out.log", commands, replies],
            environment: [
                "TMPDIR": directory + "/tmp",
                ActivationEnvironment.key(ActivationEnvironment.sharedControlPage, token: token): page.path,
            ]
        )
        guard
            let worker = try await Worker(
                module: bundle.module,
                generation: generation,
                command: command,
                commands: commands,
                replies: replies,
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
        for pass in 1...2 {
            let run = try await worker.run(
                ["skip": request.skipSwiftTesting.map(filterPattern(for:))],
                events: "\(direct.logs)/\(name)-classify-\(pass).events.jsonl",
                timeout: request.deadline
            )
            guard run?.clean == true else {
                worker.terminate()
                return nil
            }
            if let run { worker.suiteNanoseconds = max(worker.suiteNanoseconds, run.nanoseconds) }
            passes.append(page.evaluations())
        }
        page.countsEvaluations = false
        worker.processCached = Set(
            slots.filter { id in
                let atLaunch = launch[id] ?? 0
                let first = (passes[0][id] ?? 0) &- atLaunch
                let second = (passes[1][id] ?? 0) &- (passes[0][id] ?? 0)
                return atLaunch > 0 || first != second
            }
        )
        return worker
    }

    /// One helper process on one bundle, with its control page.
    final class Worker: @unchecked Sendable {
        let module: String
        let generation: Int
        let page: SharedControlPage
        var processCached: Set<String> = []
        /// How long one unmutated pass over this bundle took in this loaded worker.
        var suiteNanoseconds: Int64 = 0
        /// Mutants run so far.
        var mutants = 0
        private let process = Process()
        private let commandsLock = NSLock()
        private var commands: Int32
        private let replies: LineReader
        /// The helper's own process ID (differs from `process`'s when `simctl spawn` launched it).
        private var helperPID: Int32?

        /// What one command's run showed.
        struct Run {
            let passed: Bool
            let scan: TestEvidence.EventScan?
            let nanoseconds: Int64
            /// Passed, with a complete event stream and no failing issue.
            var clean: Bool { passed && scan?.ended == true && scan?.failed == false }
        }

        /// Makes the two FIFOs, starts `command` (stdin /dev/null, its output to `errorLog`), and opens the FIFOs in
        /// the helper's order: commands for writing, then replies. Nil when the helper does not start or never opens
        /// them within 120 s.
        init?(
            module: String,
            generation: Int,
            command: ServeCommand,
            commands commandsPath: String,
            replies repliesPath: String,
            processToken: String,
            errorLog: String,
            page: SharedControlPage
        ) async throws {
            self.module = module
            self.generation = generation
            self.page = page
            for path in [commandsPath, repliesPath] {
                guard unsafe mkfifo(path, 0o600) == 0 else { throw LitmusFailure("mkfifo \(path): errno \(errno)") }
            }
            process.executableURL = URL(fileURLWithPath: command.executable)
            process.arguments = command.arguments
            var environment = command.environment
            environment[processTokenVariable] = processToken
            process.environment = environment
            process.currentDirectoryURL = URL(fileURLWithPath: command.directory)
            process.standardInput = FileHandle.nullDevice
            FileManager.default.createFile(atPath: errorLog, contents: nil)
            let log = FileHandle(forWritingAtPath: errorLog)
            process.standardOutput = log
            process.standardError = log
            do { try process.run() } catch { return nil }
            // A writer's open fails (ENXIO) until the helper opened its end: retry while it runs.
            var writer: Int32 = -1
            let deadline = ContinuousClock.now + .seconds(120)
            while writer < 0, process.isRunning, ContinuousClock.now < deadline {
                writer = unsafe open(commandsPath, O_WRONLY | O_NONBLOCK)
                if writer < 0 { try? await Task.sleep(for: .milliseconds(20)) }
            }
            let reader = writer >= 0 ? unsafe open(repliesPath, O_RDONLY | O_NONBLOCK) : -1
            guard writer >= 0, reader >= 0 else {
                if writer >= 0 { close(writer) }
                if reader >= 0 { close(reader) }
                if process.isRunning { process.terminate() }
                return nil
            }
            _ = fcntl(writer, F_SETFL, fcntl(writer, F_GETFL) & ~O_NONBLOCK)
            _ = fcntl(writer, F_SETNOSIGPIPE, 1)
            commands = writer
            let process = process
            guard let reader = LineReader(descriptor: reader, alive: { process.isRunning }) else {
                close(writer)
                if process.isRunning { process.terminate() }
                return nil
            }
            replies = reader
        }

        func waitReady(timeout: Int) async -> Bool {
            guard case .line(let line) = await replies.next(timeout: timeout),
                let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                object["ready"] as? Bool == true
            else { return false }
            helperPID = (object["pid"] as? Int).flatMap(Int32.init(exactly:))
            return true
        }

        /// One Swift Testing run with `configuration`; nil when the helper ended or did not answer in `timeout`
        /// seconds (then it is ended).
        func run(_ configuration: [String: Any], events: String, timeout: Int) async throws -> Run? {
            let started = Date()
            let command = try JSONSerialization.data(withJSONObject: ["configuration": configuration, "events": events])
            let payload = command + Data([0x0A])
            let wrote = commandsLock.withLock { () -> Bool in
                guard commands >= 0 else { return false }
                var offset = 0
                while offset < payload.count {
                    let count = unsafe payload[offset...].withUnsafeBytes {
                        unsafe Darwin.write(commands, $0.baseAddress, $0.count)
                    }
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { return false }
                    offset += count
                }
                return true
            }
            guard wrote else { return nil }
            guard case .line(let line) = await replies.next(timeout: timeout),
                let reply = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                let passed = reply["passed"] as? Bool
            else {
                terminate()
                return nil
            }
            let nanos = Int64(Date().timeIntervalSince(started) * 1_000_000_000)
            let scan = try? TestEvidence.swiftTestingEvents(BoundedFileReader.read(path: events, cap: 64 << 20))
            return Run(passed: passed, scan: scan, nanoseconds: nanos)
        }
        func terminate() {
            // The helper inside the simulator first (`simctl spawn` would leave it behind), then the launcher, then
            // our FIFO ends so the reader thread leaves its read.
            if let pid = helperPID, pid > 1 { kill(pid, SIGKILL) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            commandsLock.withLock {
                if commands >= 0 {
                    Darwin.close(commands)
                    commands = -1
                }
            }
            replies.close()
            process.waitUntilExit()
        }
    }

    /// Lines of a non-blocking descriptor, waited on with `poll` alongside a wake pipe: `close()` wakes a waiting
    /// caller, and the descriptors close once no call is reading them (never under another descriptor's number, and
    /// never inside Foundation's `NSConcreteFileHandle` lock).
    @safe final class LineReader: @unchecked Sendable {
        enum Next { case line(Data), timedOut, ended }
        private let descriptor: Int32
        private let wake: (read: Int32, write: Int32)
        private let alive: @Sendable () -> Bool
        private let lock = NSLock()
        private var closed = false
        private var reading = false
        private var released = false
        private var pending = Data()
        private var openedWriter = false

        init?(descriptor: Int32, alive: @escaping @Sendable () -> Bool) {
            var ends: [Int32] = [-1, -1]
            guard unsafe pipe(&ends) == 0 else {
                Darwin.close(descriptor)
                return nil
            }
            for end in ends { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }
            self.descriptor = descriptor
            wake = (ends[0], ends[1])
            self.alive = alive
        }

        deinit { close() }

        func close() {
            let (shouldWake, releaseNow) = lock.withLock { () -> (Bool, Bool) in
                guard !closed else { return (false, false) }
                closed = true
                if reading { return (true, false) }
                released = true
                return (false, true)
            }
            if shouldWake {
                var byte: UInt8 = 1
                _ = unsafe write(wake.write, &byte, 1)
            }
            if releaseNow { releaseDescriptors() }
        }

        private func releaseDescriptors() {
            Darwin.close(descriptor)
            Darwin.close(wake.read)
            Darwin.close(wake.write)
        }

        func next(timeout: Int) async -> Next {
            await Task.detached { [self] in readLine(timeout: timeout) }.value
        }

        private func readLine(timeout: Int) -> Next {
            let entered = lock.withLock { () -> Bool in
                guard !closed, !reading else { return false }
                reading = true
                return true
            }
            guard entered else { return .ended }
            defer {
                let releaseNow = lock.withLock { () -> Bool in
                    reading = false
                    guard closed, !released else { return false }
                    released = true
                    return true
                }
                if releaseNow { releaseDescriptors() }
            }
            let deadline = ContinuousClock.now + .seconds(timeout)
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let buffered: Data? = lock.withLock {
                    if closed { return Data() }
                    guard let newline = pending.firstIndex(of: 0x0A) else { return nil }
                    defer { pending.removeSubrange(...newline) }
                    return Data(pending[..<newline])
                }
                if let buffered { return lock.withLock({ closed }) && buffered.isEmpty ? .ended : .line(buffered) }
                let remaining = deadline - ContinuousClock.now
                guard remaining > .zero else { return .timedOut }
                let slice = Int32(
                    min(
                        500,
                        max(
                            1,
                            remaining.components.seconds * 1_000
                                + remaining.components.attoseconds / 1_000_000_000_000_000
                        )
                    )
                )
                var descriptors = [
                    pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0),
                    pollfd(fd: wake.read, events: Int16(POLLIN), revents: 0),
                ]
                let ready = unsafe poll(&descriptors, 2, slice)
                if lock.withLock({ closed }) { return .ended }
                if ready == 0 {
                    if !alive() { return .ended }
                    continue
                }
                if ready < 0 {
                    if errno == EINTR { continue }
                    return .ended
                }
                if descriptors[1].revents != 0 { return .ended }
                while true {
                    let count = buffer.withUnsafeMutableBytes {
                        unsafe Darwin.read(descriptor, $0.baseAddress, $0.count)
                    }
                    if count > 0 {
                        lock.withLock {
                            openedWriter = true
                            pending.append(contentsOf: buffer[..<count])
                        }
                    } else if count == 0 {
                        if !lock.withLock({ openedWriter }), alive() {
                            usleep(10_000)
                            break
                        }
                        return .ended
                    } else if errno == EAGAIN || errno == EINTR {
                        break
                    } else {
                        return .ended
                    }
                }
            }
        }
    }
}

extension SwiftPMDirectHarness: SharedProcessBackend {
    var sharedBundles: [SharedBundle] {
        bundles.map {
            SharedBundle(module: $0.module, binary: $0.binaryPath, hasSwiftTesting: $0.swiftTestingCount > 0)
        }
    }

    func serveCommand(bundle: SharedBundle, helper: String, arguments: [String], environment: [String: String]) async
        -> ServeCommand
    {
        var child = subjectEnvironment(nil)
        child["DYLD_FRAMEWORK_PATH"] = toolchain.frameworks
        child["DYLD_LIBRARY_PATH"] = toolchain.libraries
        child.merge(environment) { _, new in new }
        return ServeCommand(executable: helper, arguments: arguments, environment: child, directory: workspace)
    }
}

extension SimulatorDirectHarness: SharedProcessBackend {
    var sharedBundles: [SharedBundle] {
        bundles.map { SharedBundle(module: $0.module, binary: $0.binary, hasSwiftTesting: true) }
    }

    /// `simctl spawn` on the next device of the fleet: the helper's serve mode, its environment passed as
    /// `SIMCTL_CHILD_*`. The FIFOs and the control page are host paths, which simulator processes open as they are.
    func serveCommand(bundle: SharedBundle, helper: String, arguments: [String], environment: [String: String]) async
        -> ServeCommand
    {
        guard let full = bundles.first(where: { $0.module == bundle.module }) else {
            return ServeCommand(executable: "/usr/bin/false", arguments: [], environment: [:], directory: workspace)
        }
        var variables = self.environment(nil, bundle: full)
        for (name, value) in environment { variables["SIMCTL_CHILD_" + name] = value }
        let udid = await fleet.nextDevice().udid
        let spawn = ["spawn", udid, helper, "--serve"] + arguments
        if self.helper.simctl == "/usr/bin/xcrun" {
            return ServeCommand(
                executable: "/usr/bin/xcrun",
                arguments: ["simctl"] + spawn,
                environment: variables,
                directory: workspace
            )
        }
        return ServeCommand(
            executable: self.helper.simctl,
            arguments: spawn,
            environment: variables,
            directory: workspace
        )
    }
}
