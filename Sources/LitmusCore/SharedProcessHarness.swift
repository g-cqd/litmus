internal import Foundation
internal import SourceCorpus

#if canImport(Darwin)
    internal import Darwin
#endif

/// Shared-process execution on macOS (docs/design/shared-process.md): a mutant's narrowed Swift Testing run goes to a
/// helper process that already loaded the test bundle, and the shared control page switches the mutant on.
///
/// Only kills are decided there, and only when the mutant's switch was evaluated (`activeHits > 0`) and the failing
/// tests pass again unmutated in the same process. Everything else runs in a fresh process through the direct
/// harness: XCTest, whole-suite runs, controls, survivors (always confirmed fresh), mutants the worker classified as
/// process-cached (evaluated while loading, or a different number of times in two unmutated passes), crashes,
/// timeouts and any doubt about the worker's state, after which the worker is replaced.
public final class SharedProcessHarness<Executor: ProcessExecutor>: TestHarness, @unchecked Sendable {
    let direct: SwiftPMDirectHarness<Executor>
    /// Builds (or finds in the cache) the helper program; called once, when the first worker starts.
    let buildHelper: @Sendable () async throws -> String
    let scratch: String
    let token: String
    let mode: SharedProcessMode
    public var capabilities: HarnessCapabilities { direct.capabilities }
    /// `swiftpm-shared` when always on; with `auto`, the direct harness's kind (a note says which batches used workers).
    public var kind: String { mode == .on ? "swiftpm-shared" : direct.kind }

    private let lock = NSLock()
    private var generation = 0
    /// The current batch's mutants, by slot.
    private var slots: [String] = []
    private var idle: [String: [Worker]] = [:]
    /// Modules whose worker could not be classified in this generation: fresh processes only.
    private var unshareable: Set<String> = []
    private var counts = Statistics()
    /// Whether this batch's narrowed runs go to workers: always with `on`, per batch with `auto` (``decide(covered:workers:suiteNanoseconds:spawnNanoseconds:)``).
    private var engaged: Bool
    /// The built helper, or why it could not be built (`auto` then stays off for the run).
    private var helperPath: Result<String, LitmusFailure>?

    /// What the harness decided where, for the run's notes.
    public struct Statistics: Sendable, Equatable {
        public var sharedKills = 0
        public var freshRuns = 0
        public var workersStarted = 0
        public var workersRetired = 0
        public var processCached: Set<String> = []
        /// Batches `auto` engaged, and those it left to fresh processes.
        public var batchesEngaged = 0
        public var batchesDeclined = 0
    }

    public init(
        direct: SwiftPMDirectHarness<Executor>,
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

    public var statistics: Statistics { lock.withLock { counts } }

    /// A new schema batch is built: workers of the previous build are ended, and slots follow `batch`.
    public func prepare(batch: [Mutation]) {
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
    public func shutdown() {
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
        guard !request.activeID.isEmpty, let only = request.onlySwiftTesting, !only.isEmpty,
            !request.collectPerTestReach, request.repetitions == nil,
            lock.withLock({ slots.contains(request.activeID) })
        else { return try await fresh() }
        let targets = direct.bundles.filter { bundle in
            only.contains { $0.hasPrefix(bundle.module + ".") }
                && request.onlyModules.map { $0.contains(bundle.module) } ?? true
                && !request.skipModules.contains(bundle.module)
        }
        guard !targets.isEmpty, targets.allSatisfy({ $0.swiftTestingCount > 0 }) else { return try await fresh() }
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
            case .passed:
                checkin(worker)
            case .doubt:
                retire(worker)
                return try await fresh()
            }
        }
        // Every bundle passed: a survivor is never decided in a shared process.
        return try await fresh()
    }

    private enum SharedOutcome {
        case killed(TestRunResult)
        case passed
        /// The worker's state or the run is in doubt: replace the worker and decide in a fresh process.
        case doubt
    }

    private func runShared(
        _ bundle: SwiftPMDirectHarness<Executor>.Bundle,
        worker: Worker,
        request: TestRunRequest,
        start: ContinuousClock.Instant
    ) async throws -> SharedOutcome {
        let remaining = max(1, request.deadline - Int(nanoseconds(since: start) / 1_000_000_000))
        let tests = (request.onlySwiftTesting ?? []).filter { $0.hasPrefix(bundle.module + ".") }
        let stem = "\(request.name)-\(bundle.module)-shared"
        /// The mutant's tests, once, with whatever the page holds; events in `logs/<stem><suffix>.events.jsonl`.
        func pass(_ suffix: String) async throws -> Worker.Run? {
            try await worker.run(
                Self.configuration(only: tests, skip: request.skipSwiftTesting, width: request.parallelizationWidth),
                events: "\(direct.logs)/\(stem)\(suffix).events.jsonl",
                timeout: remaining
            )
        }
        try worker.page.activate(request.activeID)
        let active = try await pass("")
        let hits = worker.page.activeHits
        try worker.page.activate(nil)
        guard let active, let scan = active.scan, scan.ended else { return .doubt }
        if !scan.failed && active.passed {
            // The mutant survived here; its run may still have left state behind. Look before the next mutant.
            return try await pass("-after")?.clean == true ? .passed : .doubt
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

    private func checkout(_ bundle: SwiftPMDirectHarness<Executor>.Bundle, request: TestRunRequest) async throws
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
        _ bundle: SwiftPMDirectHarness<Executor>.Bundle,
        generation: Int,
        slots: [String],
        request: TestRunRequest
    ) async throws -> Worker? {
        guard let helper = try await helper() else { return nil }
        let directory = scratch + "/worker-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: directory + "/tmp", withIntermediateDirectories: true)
        let page = try SharedControlPage(path: directory + "/page", slots: slots)
        page.countsEvaluations = true
        var environment = subjectEnvironment(nil)
        environment["TMPDIR"] = directory + "/tmp"
        environment[processTokenVariable] = directory
        environment["DYLD_FRAMEWORK_PATH"] = direct.toolchain.frameworks
        environment["DYLD_LIBRARY_PATH"] = direct.toolchain.libraries
        environment[ActivationEnvironment.key(ActivationEnvironment.sharedControlPage, token: token)] = page.path
        let name = "shared-\(bundle.module)-\(directory.suffix(8))"
        guard
            let worker = try Worker(
                module: bundle.module,
                generation: generation,
                helper: helper,
                arguments: [bundle.binaryPath, "\(direct.logs)/\(name).out.log"],
                environment: environment,
                directory: direct.workspace,
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
        /// Mutants run so far.
        var mutants = 0
        private let process = Process()
        private let commands: FileHandle
        private let replies: LineReader

        /// What one command's run showed.
        struct Run {
            let passed: Bool
            let scan: TestEvidence.EventScan?
            /// Passed, with a complete event stream and no failing issue.
            var clean: Bool { passed && scan?.ended == true && scan?.failed == false }
        }

        init?(
            module: String,
            generation: Int,
            helper: String,
            arguments: [String],
            environment: [String: String],
            directory: String,
            errorLog: String,
            page: SharedControlPage
        ) throws {
            self.module = module
            self.generation = generation
            self.page = page
            let input = Pipe(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: helper)
            process.arguments = arguments
            process.environment = environment
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            process.standardInput = input
            process.standardOutput = output
            FileManager.default.createFile(atPath: errorLog, contents: nil)
            process.standardError = FileHandle(forWritingAtPath: errorLog)
            commands = input.fileHandleForWriting
            replies = LineReader(output.fileHandleForReading)
            do { try process.run() } catch { return nil }
        }

        func waitReady(timeout: Int) async -> Bool {
            guard case .line(let line) = await replies.next(timeout: timeout) else { return false }
            return (try? JSONSerialization.jsonObject(with: line) as? [String: Any])?["ready"] as? Bool == true
        }

        /// One Swift Testing run with `configuration`; nil when the helper ended or did not answer in `timeout`
        /// seconds (then it is ended).
        func run(_ configuration: [String: Any], events: String, timeout: Int) async throws -> Run? {
            let command = try JSONSerialization.data(withJSONObject: ["configuration": configuration, "events": events])
            do { try commands.write(contentsOf: command + Data([0x0A])) } catch { return nil }
            guard case .line(let line) = await replies.next(timeout: timeout),
                let reply = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                let passed = reply["passed"] as? Bool
            else {
                terminate()
                return nil
            }
            let scan = try? TestEvidence.swiftTestingEvents(BoundedFileReader.read(path: events, cap: 64 << 20))
            return Run(passed: passed, scan: scan)
        }

        func terminate() {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? commands.close()
            process.waitUntilExit()
        }
    }

    /// Lines of a pipe, read on a thread of their own so a wait can time out.
    final class LineReader: @unchecked Sendable {
        enum Next { case line(Data), timedOut, ended }
        private let condition = NSCondition()
        private var lines: [Data] = []
        private var ended = false

        init(_ handle: FileHandle) {
            let thread = Thread { [self] in
                var pending = Data()
                while true {
                    let chunk = handle.availableData
                    condition.lock()
                    if chunk.isEmpty {
                        ended = true
                        condition.broadcast()
                        condition.unlock()
                        return
                    }
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: 0x0A) {
                        lines.append(pending[pending.startIndex..<newline])
                        pending = pending[pending.index(after: newline)...]
                    }
                    condition.broadcast()
                    condition.unlock()
                }
            }
            thread.start()
        }

        /// The next line, waiting at most `timeout` seconds on a thread of the cooperative pool's choosing.
        func next(timeout: Int) async -> Next {
            await Task.detached { [self] in waitForLine(timeout: timeout) }.value
        }

        private func waitForLine(timeout: Int) -> Next {
            let deadline = Date(timeIntervalSinceNow: TimeInterval(timeout))
            condition.lock()
            defer { condition.unlock() }
            while lines.isEmpty && !ended {
                if !condition.wait(until: deadline) { return .timedOut }
            }
            return lines.isEmpty ? .ended : .line(Data(lines.removeFirst()))
        }
    }
}
