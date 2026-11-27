internal import Foundation

extension RunSession {
    /// The schema batches still to build, and what bisection has spent on them.
    struct BatchQueue {
        var pending: [[Mutation]]
        /// The bisection budget left to each mutant's lineage of failing controls.
        var controlBudget: [String: Int] = [:]
        var lastBuild = Duration.zero
        var buildIndex = 0
    }

    /// How many schema builds a lineage of one batch may spend isolating the mutants that break its control: enough
    /// to find a few of them, not enough to chase a failure that is not theirs.
    static func bisectBudget(for count: Int) -> Int { 3 * (Int.bitWidth - count.leadingZeroBitCount + 1) }

    /// Builds each batch's schema, bisects the ones that do not compile, controls and judges the reached mutants.
    func runBatches() async throws {
        var established: Established?
        var unmutatedBuilt = false
        /// Each test's counts alone (per-test reach), across schemas.
        var perTestCounts: [String: TestCounts] = [:]
        if !options.inactiveSchemaBaseline {
            try await buildUnmutated()
            unmutatedBuilt = true
            established = try await establish()
            artifact.policy?.baselineBuild = "unmutated"
        }
        // Changed-line mutants are batched apart and first: a budget spends itself on them before the rest.
        let first = Set(plan.scope?.onChangedLines ?? toRun.map(\.id))
        let classes = [toRun.filter { first.contains($0.id) }, toRun.filter { !first.contains($0.id) }]
        var queue = BatchQueue(
            pending: Array(classes.flatMap { SchemaWriter.batches($0, limit: options.batchSize) }.reversed())
        )
        while var group = queue.pending.popLast() {
            try Task.checkCancellation()
            if let budgetEnd, clock.now + queue.lastBuild > budgetEnd {
                // Not started: the next build would end past the budget (estimated by the last one).
                try runner.untested(
                    group + queue.pending.flatMap { $0 },
                    "the time budget (\(options.budgetSeconds ?? 0) s) ran out before its schema was built",
                    stoppedBy: "time",
                    into: &artifact,
                    sink
                )
                queue.pending.removeAll()
                break
            }
            queue.buildIndex += 1
            let name = "schema-\(queue.buildIndex)"
            let (installedGroup, build) = try await buildSchema(group, name: name, queue: &queue)
            guard build.exitStatus == 0, !build.timedOut else {
                try installedGroup.restore()
                installed = nil
                if established == nil, !unmutatedBuilt {
                    // No baseline yet: the unmutated build tells a broken subject (the run stops) from mutants that
                    // do not compile (the group is split below), and becomes the baseline.
                    try await buildUnmutated()
                    unmutatedBuilt = true
                    established = try await establish()
                    artifact.policy?.baselineBuild = "unmutated (the first schema did not build)"
                }
                try splitUnbuilt(group, name: name, build: build, installed: installedGroup, queue: &queue)
                continue
            }
            let control: Judge.Execution
            let current: Established
            if let known = established {
                guard
                    let passed = try await controlRun(
                        group,
                        name: name,
                        known: known,
                        installed: installedGroup,
                        queue: &queue
                    )
                else { continue }
                (current, control) = (known, passed)
            } else {
                // The inactive schema is the baseline: with no mutant active every site evaluates its original
                // expression, so this build behaves as the unmutated one, and its run is the control too.
                current = try await establish()
                established = current
                artifact.policy?.baselineBuild = "inactive-schema"
                control = current.baseline
                phase = clock.now
            }
            var judge = current.judge
            // Shared workers loaded the previous build: they end, and slots follow this batch's schema.
            (judge.harness as? any SharedProcessControl)?.prepare(batch: group)
            let covered = try cover(&group, control: control, judge: &judge, workers: current.workerCount)
            (judge.harness as? any UISessionControl)?.register(covered.map { ($0.id, judge.covering[$0.id]) })
            try await collectReach(
                covered,
                control: control,
                established: current,
                judge: &judge,
                name: name,
                perTestCounts: &perTestCounts
            )
            judge.testCounts.merge(perTestCounts) { _, new in new }
            try await decide(covered, judge: judge, workers: current.workerCount, name: name)
            account("tests", since: phase)
            try installedGroup.restore()
            installed = nil
            try ArtifactCodec.write(artifact, path: checkpointPath)
        }
        summarizeBatches(established)
    }

    /// Installs `group`'s schema into the workspace and builds it.
    func buildSchema(_ group: [Mutation], name: String, queue: inout BatchQueue) async throws -> (
        InstalledSchema, ProcessOutput
    ) {
        let installedGroup = try runner.install(
            group,
            in: snapshot,
            journal: prepared.restore,
            token: options.environmentToken
        )
        installed = installedGroup
        phase = clock.now
        counter.build()
        let build = try await executor.execute(
            driver.buildCommand(workspace: snapshot.root, artifacts: artifacts),
            directory: driver.executionDirectory(workspace: snapshot.root),
            environment: subjectEnvironment(nil),
            timeout: options.buildTimeout,
            supervision: buildSupervision
        )
        queue.lastBuild = clock.now - phase
        try writeLog(build, path: "\(logs)/\(name)-build.log")
        account("build", since: phase)
        return (installedGroup, build)
    }

    /// A schema that did not build: a lone mutant is unviable when the compiler blames its own file; a group splits
    /// on the mutants the diagnostics name, else in halves.
    func splitUnbuilt(
        _ group: [Mutation],
        name: String,
        build: ProcessOutput,
        installed installedGroup: InstalledSchema,
        queue: inout BatchQueue
    ) throws {
        let diagnostics = CompilerDiagnostics(build, snapshotRoot: snapshot.root)
        if build.timedOut {
            for site in group {
                try runner.record(
                    site,
                    .infrastructureError,
                    "schema build timed out",
                    ["logs/\(name)-build.log"],
                    into: &artifact,
                    sink
                )
            }
        } else if group.count == 1, let site = group.first {
            // Unviable only when the compiler reports an error in the mutant's own file: this build changed nothing
            // else. Flow errors ("missing return" after a negated `while true`) point at the end of the function,
            // not at the mutant's lines. No error, or errors only elsewhere: not its doing.
            let mutated = Set(installedGroup.rendered.keys)
            let own = diagnostics.errors.first { mutated.contains($0.path) }
            let message = (own ?? diagnostics.errors.first)?.message ?? "no compiler diagnostic"
            try runner.record(
                site,
                own != nil ? .unviable : .infrastructureError,
                own != nil ? "does not compile: \(message)" : "schema build failed elsewhere: \(message)",
                ["logs/\(name)-build.log"],
                into: &artifact,
                sink
            )
        } else {
            let suspects = Set(diagnostics.suspects(in: installedGroup.rendered))
            let named = group.filter { suspects.contains($0.id) }
            if !named.isEmpty, named.count < group.count {
                queue.pending.append(named)
                queue.pending.append(group.filter { !suspects.contains($0.id) })
            } else {
                let middle = group.count / 2
                queue.pending.append(Array(group[middle...]))
                queue.pending.append(Array(group[..<middle]))
            }
        }
    }

    /// The schema's run with no mutant active, which must match the baseline; nil when it did not, after bisecting
    /// the group or recording its mutants.
    func controlRun(
        _ group: [Mutation],
        name: String,
        known: Established,
        installed installedGroup: InstalledSchema,
        queue: inout BatchQueue
    ) async throws -> Judge.Execution? {
        phase = clock.now
        let singlePassReach =
            options.perTestReach && known.judge.harness.selectsTests && known.judge.harness.controlsSwiftTesting
        let first = try await known.judge.execute(
            name: "\(name)-control",
            activeID: "",
            deadline: known.deadline,
            collectPerTestReach: singlePassReach
        )
        func sound(_ execution: Judge.Execution) -> Bool {
            execution.result.outcome == .passed && execution.result.counts == known.counts
        }
        if sound(first) { return first }
        // One failure may be the machine or a flaky test, not the schema: look again before blaming a mutant.
        let again = try await known.judge.execute(
            name: "\(name)-control-retry",
            activeID: "",
            deadline: known.deadline,
            collectPerTestReach: singlePassReach
        )
        if sound(again) {
            artifact.notes.append(
                "the inactive control of \(name) failed once and passed on retry (a flaky test or a busy machine); its verdicts stand"
            )
            return again
        }
        try installedGroup.restore()
        installed = nil
        account("tests", since: phase)
        let remaining = queue.controlBudget[group[0].id] ?? Self.bisectBudget(for: group.count)
        if group.count > 1, remaining > 0 {
            artifact.notes.append(
                "the inactive control of \(name) differs from the unmutated baseline (\(again.result.reason)); bisecting its \(group.count) mutants"
            )
            let middle = group.count / 2
            for site in group { queue.controlBudget[site.id] = remaining - 1 }
            queue.pending.append(Array(group[middle...]))
            queue.pending.append(Array(group[..<middle]))
            return nil
        }
        let why =
            group.count == 1
            ? "its inactive schema makes the suite differ from the unmutated baseline"
            : "the inactive control kept differing and the bisection budget is spent"
        for site in group {
            try runner.record(
                site,
                .infrastructureError,
                "\(why): \(again.result.reason)",
                again.result.evidence,
                into: &artifact,
                sink
            )
        }
        return nil
    }

    /// The run's timing summary and shared-process statistics, once every batch is done.
    func summarizeBatches(_ established: Established?) {
        if let sessions = (established?.judge.harness as? any UISessionControl)?.statistics, sessions.sessions > 0 {
            artifact.notes.append(
                "UI sessions: \(sessions.sessions) xcodebuild session(s) decided \(sessions.served) first run(s), one "
                    + "test-plan configuration per mutant; \(sessions.fallbacks) ran fresh instead"
            )
        }
        if let timings = established?.judge.timings {
            artifact.notes += timings.summary(
                factor: options.timeoutFactor,
                minimum: options.minimumTimeout,
                cap: established?.deadline ?? options.timeoutCap
            )
        }
        guard let shared = established?.judge.harness as? any SharedProcessControl else { return }
        shared.shutdown()
        let statistics = shared.statistics
        guard shared.mode == .on || statistics.batchesEngaged > 0 else { return }
        artifact.notes.append(
            "shared process: \(statistics.sharedKills) kill(s) and \(statistics.sharedPasses) narrowed pass(es) "
                + "in shared workers, \(statistics.freshRuns) run(s) in fresh processes; \(statistics.workersStarted) worker(s) "
                + "started, \(statistics.workersRetired) replaced; \(statistics.processCached.count) "
                + "process-cached mutant(s) always run fresh"
        )
    }
}
