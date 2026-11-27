internal import Foundation

extension Judge {
    /// One suite execution on a free worker, with fresh marker and temporary directories.
    func execute(
        name: String,
        activeID: String,
        deadline: Int,
        failFast: Bool = false,
        only: [String]? = nil,
        modules: Set<String>? = nil,
        repetitions: Int? = nil,
        alone: Bool = false,
        collectPerTestReach: Bool = false
    ) async throws -> Execution {
        let slot = try await pool.acquire()
        defer { pool.checkin(slot) }
        counter.test()
        let unique = UUID().uuidString.prefix(8)
        let coverage = "\(slot.directory)/coverage-\(unique)", temporary = "\(slot.directory)/tmp-\(unique)"
        for directory in [coverage, temporary] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        defer {
            try? FileManager.default.removeItem(atPath: coverage)
            try? FileManager.default.removeItem(atPath: temporary)
        }
        var request = TestRunRequest(
            name: name,
            activeID: activeID,
            coverageDirectory: coverage,
            temporaryDirectory: temporary,
            deadline: deadline,
            failFast: failFast
        )
        request.onlySwiftTesting = only
        request.collectPerTestReach = collectPerTestReach
        request.environmentToken = options.environmentToken
        request.skipModules = quarantined
        request.alone = alone
        request.rechecksNarrowedSurvivors = options.recheckSurvivors
        // A run alone decides a timeout: never at background priority.
        request.supervision = options.supervision(background: alone ? false : nil)
        if harness.selectsModules { request.onlyModules = only == nil ? modules : nil }
        if harness.controlsSwiftTesting {
            request.skipSwiftTesting = skip
            request.repetitions = repetitions
            request.parallelizationWidth = options.suiteWidth
        }
        let result = try await harness.run(request)
        return Execution(result: result, reached: ActivationEnvironment.reached(in: coverage))
    }

    /// Accumulates the evidence and time of one mutant's runs.
    struct Ledger {
        let site: Mutation
        let baseline: TestCounts
        var evidence: [String]
        var nanoseconds: Int64

        func decision(_ verdict: Verdict, _ reason: String, _ tests: TestCounts? = nil) -> Decision {
            Decision(
                site: site,
                verdict: verdict,
                reason: reason,
                evidence: evidence,
                nanoseconds: nanoseconds,
                tests: tests
            )
        }

        func passing(_ execution: Execution) -> Decision {
            guard let counts = execution.result.counts, counts.passed == baseline.passed, counts.total == baseline.total
            else {
                return decision(.infrastructureError, "the passing run's test population differs from the baseline")
            }
            return execution.reached.contains(site.id)
                ? decision(.survived, "every test passed after the mutated code ran", counts)
                : decision(.noCoverage, "the control reached the mutated code, the active run did not", counts)
        }
    }

    func run(
        _ site: Mutation,
        _ suffix: String,
        active: Bool,
        deadline: Int,
        only: [String]? = nil,
        ledger: inout Ledger
    ) async throws -> Execution {
        // Every run of a mutant uses the same tests: its reaching ones when selected, so counts compare.
        let tests = only ?? selected(site)
        let kind = MutantTimings.kind(tests: tests, modules: covering[site.id])
        let execution = try await execute(
            name: "mutant-\(site.id)\(suffix)",
            activeID: active ? site.id : "",
            deadline: timings.deadline(
                kind: kind,
                cap: deadline,
                factor: options.timeoutFactor,
                minimum: options.minimumTimeout,
                alone: !suffix.isEmpty
            ),
            failFast: active && options.failFast,
            only: tests,
            modules: covering[site.id],
            alone: !suffix.isEmpty
        )
        // A fresh first run that ended on its own is a sample; a shared worker's millisecond run or a timeout never
        // sets the deadline of a fresh process.
        if suffix.isEmpty, !execution.result.ranInSharedWorker,
            execution.result.outcome == .passed || execution.result.outcome == .failed
        {
            timings.record(execution.result.nanoseconds, kind: kind)
        }
        ledger.evidence += execution.result.evidence
        ledger.nanoseconds += execution.result.nanoseconds
        return execution
    }

    /// Whether per-test reach rejects a failure: it is known for the mutant, the failing tests are named, and none of
    /// them reaches the mutant (the fcheck timing test's false kills, study 4).
    func reachRejects(_ site: Mutation, failing: [String]) -> Bool {
        guard let tests = reach[site.id], !failing.isEmpty else { return false }
        return tests.isDisjoint(with: failing)
    }
}
