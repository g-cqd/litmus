internal import Foundation
internal import SourceCorpus
internal import Synchronization

/// Runs narrowed Swift Testing requests inside long-lived helper processes, switching mutants via `SharedControlPage`.
final class SharedProcessHarness<Backend: SharedProcessBackend>: TestHarness, SharedProcessControl, Sendable {
    static var minimumSpawnNanoseconds: Int64 { 250_000_000 }
    static var mutantsPerWorker: Int { 32 }

    let direct: Backend
    let buildHelper: @Sendable () async throws -> String
    let scratch: String
    let token: String
    let mode: SharedProcessMode

    private struct State {
        var generation = 0
        var slots: [String] = []
        var idle: [String: [SharedWorker]] = [:]
        var unshareable: Set<String> = []
        var counts = SharedProcessStatistics()
        var engaged: Bool
        var helperPath: Result<String, LitmusFailure>?
    }

    private let state: Mutex<State>

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
        self.state = Mutex(State(engaged: mode == .on))
    }

    deinit { shutdown() }

    public var capabilities: HarnessCapabilities { direct.capabilities }
    public var kind: String {
        guard mode == .on else { return direct.kind }
        return (direct.kind.hasSuffix("-direct") ? String(direct.kind.dropLast("-direct".count)) : direct.kind)
            + "-shared"
    }
    var statistics: SharedProcessStatistics { state.withLock { $0.counts } }
    var bundleCount: Int { direct.sharedBundles.count }

    static func breaksEven(covered: Int, workers: Int, suiteNanoseconds: Int64, spawnNanoseconds: Int64) -> Bool {
        guard covered >= 8, spawnNanoseconds >= minimumSpawnNanoseconds else { return false }
        let saved = Double(covered) * Double(spawnNanoseconds)
        let cost = Double(max(1, workers)) * (2 * Double(suiteNanoseconds) + Double(spawnNanoseconds))
        return saved > cost
    }

    func decide(covered: Int, workers: Int, suiteNanoseconds: Int64, spawnNanoseconds: Int64) -> String? {
        guard mode == .auto else { return nil }
        let pays = Self.breaksEven(
            covered: covered,
            workers: workers,
            suiteNanoseconds: suiteNanoseconds,
            spawnNanoseconds: spawnNanoseconds
        )
        let available = state.withLock { s in
            let ok = (try? s.helperPath?.get()) != nil || s.helperPath == nil
            s.engaged = pays && ok
            if s.engaged { s.counts.batchesEngaged += 1 } else { s.counts.batchesDeclined += 1 }
            return ok
        }
        guard available else { return nil }
        let seconds = { (nanos: Int64) in (Double(nanos) / 1e7).rounded() / 100 }
        return
            "shared process (auto): \(pays ? "on" : "off") for \(covered) covered mutant(s) and \(workers) worker(s); "
            + "process start ~\(seconds(spawnNanoseconds)) s, bundle suite ~\(seconds(suiteNanoseconds)) s per bundle"
    }

    func prepare(batch: [Mutation]) {
        let retired: [SharedWorker] = state.withLock { s in
            s.generation += 1
            s.slots = SharedControlLayout.slots(for: batch).sorted { $0.value < $1.value }.map(\.key)
            s.unshareable = []
            defer { s.idle = [:] }
            return s.idle.values.flatMap { $0 }
        }
        for worker in retired { worker.terminate() }
    }

    func shutdown() {
        let retired: [SharedWorker] = state.withLock { s in
            defer { s.idle = [:] }
            return s.idle.values.flatMap { $0 }
        }
        for worker in retired { worker.terminate() }
    }

    public func run(_ request: TestRunRequest) async throws -> TestRunResult {
        let start = ContinuousClock.now
        let isEngaged = state.withLock { $0.engaged }
        func fresh() async throws -> TestRunResult {
            if isEngaged { state.withLock { $0.counts.freshRuns += 1 } }
            return try await direct.run(request)
        }
        guard isEngaged,
            !request.activeID.isEmpty,
            !request.alone,
            let only = request.onlySwiftTesting,
            !only.isEmpty,
            !request.collectPerTestReach,
            request.repetitions == nil,
            state.withLock({ $0.slots.contains(request.activeID) })
        else { return try await fresh() }

        let targets = direct.sharedBundles.filter { bundle in
            only.contains { $0.hasPrefix(bundle.module + ".") }
                && (request.onlyModules.map { $0.contains(bundle.module) } ?? true)
                && !request.skipModules.contains(bundle.module)
        }
        guard !targets.isEmpty, targets.allSatisfy(\.hasSwiftTesting) else { return try await fresh() }

        var passed = 0, skipped = 0
        var evidence: [String] = []
        var scans: [TestEvidence.EventScan] = []
        var wasHit = false
        for bundle in targets {
            guard let worker = try await checkout(bundle, request: request) else { return try await fresh() }
            if worker.isProcessCached(request.activeID) {
                checkin(worker)
                return try await fresh()
            }
            worker.recordMutantAttempt()
            switch try await runShared(bundle, worker: worker, request: request, start: start) {
            case .killed(let result):
                checkin(worker)
                state.withLock { $0.counts.sharedKills += 1 }
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
        guard request.rechecksNarrowedSurvivors else { return try await fresh() }
        if wasHit {
            FileManager.default.createFile(atPath: request.coverageDirectory + "/" + request.activeID, contents: nil)
        }
        state.withLock { $0.counts.sharedPasses += 1 }
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
        case doubt
    }

    private func runShared(
        _ bundle: SharedBundle,
        worker: SharedWorker,
        request: TestRunRequest,
        start: ContinuousClock.Instant
    ) async throws -> SharedOutcome {
        let remaining = max(1, request.deadline - Int(nanoseconds(since: start) / 1_000_000_000))
        let runTimeout = min(remaining, max(3, 4 * Int(worker.suiteNanoseconds / 1_000_000_000) + 2))
        let tests = (request.onlySwiftTesting ?? []).filter { $0.hasPrefix(bundle.module + ".") }
        let stem = "\(request.name)-\(bundle.module)-shared"
        let config = Self.configuration(
            only: tests,
            skip: request.skipSwiftTesting,
            width: request.parallelizationWidth
        )
        func pass(_ suffix: String) async throws -> SharedWorker.Run? {
            try await worker.run(config, events: "\(direct.logs)/\(stem)\(suffix).events.jsonl", timeout: runTimeout)
        }
        try worker.page.activate(request.activeID)
        let active = try await pass("")
        let hits = worker.page.activeHits
        try worker.page.activate(nil)
        guard let active, let scan = active.scan, scan.ended else { return .doubt }
        if !scan.failed && active.passed {
            guard try await pass("-after")?.clean == true else { return .doubt }
            return .passed(scan, ["logs/\(stem).events.jsonl", "logs/\(stem)-after.events.jsonl"], hits > 0)
        }
        let failing = scan.failedTests.map(testName).sorted()
        guard hits > 0, !failing.isEmpty, try await pass("-control")?.clean == true else { return .doubt }
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

    static func configuration(only: [String], skip: [String], width: Int?) -> SharedWorkerConfiguration {
        SharedWorkerConfiguration(
            filter: only.map(filterPattern(for:)),
            skip: skip.isEmpty ? nil : skip.map(filterPattern(for:)),
            experimentalMaximumParallelizationWidth: width
        )
    }

    private func helper() async throws -> String? {
        if let known = state.withLock({ $0.helperPath }) {
            switch known {
            case .success(let path): return path
            case .failure(let failure): if mode == .on { throw failure } else { return nil }
            }
        }
        do {
            let path = try await buildHelper()
            state.withLock { $0.helperPath = .success(path) }
            return path
        } catch {
            let failure = LitmusFailure("the shared-process helper is unavailable: \(error)")
            state.withLock { s in
                s.helperPath = .failure(failure)
                if mode == .auto { s.engaged = false }
            }
            if mode == .on { throw failure }
            return nil
        }
    }

    private func checkout(_ bundle: SharedBundle, request: TestRunRequest) async throws -> SharedWorker? {
        let (reused, current, batch, refused): (SharedWorker?, Int, [String], Bool) = state.withLock { s in
            (s.idle[bundle.module]?.popLast(), s.generation, s.slots, s.unshareable.contains(bundle.module))
        }
        if let reused { return reused }
        guard !refused, let helperPath = try await helper() else { return nil }
        let worker = try await SharedWorker.spawn(
            bundle: bundle,
            generation: current,
            slots: batch,
            helper: helperPath,
            scratch: scratch,
            token: token,
            direct: direct,
            request: request
        )
        state.withLock { s in
            if let worker {
                s.counts.workersStarted += 1
                s.counts.processCached.formUnion(worker.cachedMutants)
            } else if s.generation == current {
                s.unshareable.insert(bundle.module)
            }
        }
        return worker
    }

    private func checkin(_ worker: SharedWorker) {
        let keep = state.withLock { s in
            guard worker.generation == s.generation, worker.mutantsRun < Self.mutantsPerWorker else { return false }
            s.idle[worker.module, default: []].append(worker)
            return true
        }
        if !keep { worker.terminate() }
    }

    private func retire(_ worker: SharedWorker) {
        state.withLock { $0.counts.workersRetired += 1 }
        worker.terminate()
    }
}
