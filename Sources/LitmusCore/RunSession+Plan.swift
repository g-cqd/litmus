internal import Foundation

extension RunSession {
    /// Plans the sites in the workspace and records the run's provenance and checkpoint state.
    func planAndProvenance() async throws {
        account("snapshot", since: phase)
        if options.allTestTargets {
            guard prepared.restore == nil, let container = driver.container else {
                throw LitmusFailure("--all-test-targets needs --project and a copied workspace (not in-place)")
            }
            let scheme = try SynthesizedScheme.install(
                workspace: snapshot.root,
                container: container,
                includeUITests: options.includeUITests
            )
            prepared.notes.append(
                "scheme \(SynthesizedScheme.name) synthesized in the workspace for \(scheme.targets.count) test "
                    + "target(s): \(scheme.targets.joined(separator: ", "))"
            )
            if !scheme.outside.isEmpty {
                prepared.notes.append(
                    "--all-test-targets left out workspace projects outside the copied root: "
                        + scheme.outside.joined(separator: ", ")
                )
            }
        }
        try driver.validatePackage(workspace: snapshot.root)
        try XcodeTestConfiguration.preflight(driver: driver, workspace: snapshot.root)
        phase = clock.now
        let clonePlan = try await MutationPlanner.plan(
            root: snapshot.root,
            exclude: options.exclude,
            include: options.include,
            packagePath: driver.packagePath,
            jobs: 8,
            scope: options.scope,
            operators: options.operators,
            aridCalls: options.aridCalls,
            excludeDeclarations: options.excludeDeclarations,
            indexedRoot: root,
            indexStorePath: options.indexStorePath
        )
        account("plan", since: phase)
        var rooted = MutationPlan(
            root: root,
            analyzedFiles: clonePlan.analyzedFiles,
            mutations: clonePlan.mutations,
            suppressed: clonePlan.suppressed,
            notes: clonePlan.notes
        )
        rooted.scope = clonePlan.scope
        rooted.skipped = clonePlan.skipped
        // Accepted mutants leave the plan; `--only-id` and `--verify-accepted` keep them, to run what was asked.
        if let loaded = try AcceptedMutants.load(root: root, path: options.acceptedFile) {
            rooted = AcceptedMutants.apply(
                loaded.file,
                path: loaded.path,
                to: rooted,
                verify: options.verifyAccepted || !options.onlyIDs.isEmpty
            )
        }
        plan = rooted
        // `--only-id`: only the selected files are rewritten into the workspace, only their mutants run.
        if !options.onlyIDs.isEmpty {
            var selected = MutationPlan(
                root: root,
                analyzedFiles: plan.analyzedFiles,
                mutations: try MutationSelector.select(plan.mutations, by: options.onlyIDs),
                suppressed: plan.suppressed,
                notes: plan.notes
            )
            selected.scope = plan.scope
            selected.skipped = plan.skipped
            selected.acceptance = plan.acceptance
            plan = selected
        }
        guard !plan.mutations.isEmpty else {
            throw LitmusFailure("no mutable production sites; inspect plan exclusions")
        }
        nightly = try options.reachFrom.map { try ArtifactCodec.read(RunArtifact.self, path: $0) }
        var shardRecord: ShardRecord?
        if let shard = options.shard {
            (plan, shardRecord) = Sharding.select(plan, shard, prior: nightly)
        }
        guard Set(plan.mutations.map(\.id)).count == plan.mutations.count else {
            throw LitmusFailure("mutation ID collision")
        }
        let toolchain = try await executor.execute(
            ToolCommand(
                executable: "/usr/bin/xcrun",
                arguments: [driver.usesXcode ? "xcodebuild" : "swift", "-version"]
            ),
            directory: driver.executionDirectory(workspace: snapshot.root),
            environment: subjectEnvironment(nil),
            timeout: 60
        )
        guard toolchain.exitStatus == 0 else { throw LitmusFailure("toolchain identification failed") }
        provenance = RunProvenance(
            toolVersion: LitmusVersion.current,
            snapshotSHA256: snapshot.digest,
            inputs: snapshot.entries,
            driver: driver,
            toolchain: String(decoding: toolchain.stdout, as: UTF8.self),
            startedAt: ISO8601DateFormatter().string(from: Date()),
            executionPolicy: RunArtifact.executionPolicy
        )
        artifact = RunArtifact(provenance: provenance, plan: plan)
        artifact.shard = shardRecord
        for link in snapshot.skippedLinks {
            artifact.notes.append("symbolic link left out of the workspace (never followed): \(link)")
        }
        artifact.notes += prepared.notes
        if let resolvedDestinationNote { artifact.notes.append(resolvedDestinationNote) }
        if prepared.restore != nil {
            // In place: every file to mutate must be tracked and unmodified, so git can restore it as a last resort.
            try await runner.requireCleanGit(Set(plan.mutations.map(\.path)).sorted(), root: root)
            artifact.notes.append(
                "in place: the subject root is the workspace; originals are backed up in .litmus/restore before each "
                    + "rewrite and restored after each batch"
            )
        }

    }

    /// Reuse: every result carries its key, so any run can be resumed or seed a store; a verdict is reused only when
    /// its key matches, and says where it came from.
    func applyReuse() async throws {
        phase = clock.now
        phase = clock.now
        reuse = try ReuseContext(
            mode: options.reuseMode,
            root: snapshot.root,
            entries: snapshot.entries,
            wholeSnapshot: snapshot.digest,
            mutations: plan.mutations,
            closureKnown: driver.container == nil,
            inPlace: prepared.restore != nil,
            context: ReuseContextInputs(
                toolVersion: LitmusVersion.current,
                executionPolicy: RunArtifact.executionPolicy,
                toolchain: provenance.toolchain,
                driver: driver,
                harness: options.harness.rawValue + (options.simulatorHarness ? "" : "/xcodebuild"),
                failFast: options.failFast,
                killConfirmation: options.killConfirmation.rawValue,
                memoryLimitMiB: options.memoryLimitMiB,
                timeoutCap: options.timeoutCap,
                timeoutFactor: options.timeoutFactor,
                minimumTimeout: options.minimumTimeout,
                baselineRepetitions: options.baselineRepetitions,
                suiteWidth: options.suiteWidth,
                selectTestTargets: options.selectTestTargets,
                background: options.background,
                excluded: options.exclude.sorted()
            )
        )
        for index in artifact.results.indices {
            artifact.results[index].reuseKey = reuse.key(artifact.results[index].mutation)
        }
        if !reuse.outsideRoot.isEmpty {
            artifact.notes.append(
                "\(reuse.outsideRoot.count) file(s) belong to a package depending on a local package outside the root; "
                    + "their verdicts are never reused (the root's inventory cannot see those files change)"
            )
        }
        store = try options.resultStore.map {
            try ResultStore(
                directory: $0,
                readOnly: options.storeReadOnly,
                limitMiB: options.storeLimitMiB,
                forbidden: root,
                secret: ProcessInfo.processInfo.environment["LITMUS_STORE_KEY"]
            )
        }
        let previous = try options.resume.map { try Runner.previousResults(runDirectory: $0) } ?? [:]
        let checkpointPath = output + "/run.json"
        try ArtifactCodec.write(artifact, path: checkpointPath)
        sink = Sink(
            journal: try ResultJournal(path: output + "/results.journal"),
            store: store,
            runID: provenance.runID,
            progress: options.progress ? ProgressReporter.standardError(total: plan.mutations.count) : nil
        )
        if let resume = options.resume { durationHints = Runner.previousDurations(runDirectory: resume) }
        for result in nightly?.results ?? [] where result.nanoseconds > 0 {
            durationHints[result.mutation.id] = durationHints[result.mutation.id] ?? result.nanoseconds
        }
        var reused: (resumed: Int, stored: Int) = (0, 0)
        // Selected mutants are re-verified after a test edit: an earlier verdict would answer for the old tests.
        let reusable = options.onlyIDs.isEmpty ? plan.mutations : []
        if !options.onlyIDs.isEmpty {
            artifact.notes.append(
                "--only-id: \(plan.mutations.count) mutant(s) selected and executed; stored and resumed verdicts not "
                    + "reused, the store entry is overwritten"
            )
        }
        for mutation in reusable {
            guard let key = artifact.results.first(where: { $0.mutation.id == mutation.id })?.reuseKey else { continue }
            let resumed = previous[key]
            guard let hit = resumed ?? store?.lookup(key, mutation: mutation) else { continue }
            var result = MutationResult(
                mutation: mutation,
                verdict: hit.result.verdict,
                tests: hit.result.tests,
                reason: hit.result.reason,
                evidence: resumed != nil ? hit.result.evidence : [],
                nanoseconds: hit.result.nanoseconds
            )
            result.reusedFrom = hit.result.reusedFrom ?? (hit.runID + (reuse.mode == .closure ? "" : " (declaration)"))
            try runner.record(result, into: &artifact, sink)
            if resumed != nil { reused.resumed += 1 } else { reused.stored += 1 }
        }
        artifact.reuse = ReuseRecord(
            mode: reuse.mode,
            context: reuse.context,
            store: store?.directory,
            storeReadOnly: store?.readOnly,
            resumedFrom: options.resume,
            resumed: reused.resumed,
            fromStore: reused.stored
        )
        if reused.resumed + reused.stored > 0 {
            artifact.notes.append(
                "\(reused.resumed + reused.stored) verdict(s) reused (\(reused.resumed) resumed, \(reused.stored) "
                    + "from the store), each labelled with the run that decided it; key mode \(reuse.mode.rawValue)"
            )
        }
        account("reuse", since: phase)
    }

    /// What runs: the mutants without a reused verdict, in plan order (changed lines first), within the budget.
    func selectWork() async throws {
        let decided = Set(artifact.results.filter { $0.reusedFrom != nil }.map(\.mutation.id))
        toRun = plan.mutations.filter { !decided.contains($0.id) }
        if options.budgetSeconds != nil || options.maxMutants != nil {
            artifact.budget = BudgetRecord(seconds: options.budgetSeconds, maxMutants: options.maxMutants)
        }
        if let limit = options.maxMutants, toRun.count > limit {
            let over = Array(toRun[limit...])
            toRun = Array(toRun[..<limit])
            try runner.untested(over, "beyond --max-mutants \(limit)", stoppedBy: "max-mutants", into: &artifact, sink)
        }

        // Builds run at the run's priority, without the memory limit: a compiler may use more than a test should.
        buildSupervision = Supervision()
        buildSupervision.background = options.background
        narrowXcodeBuild()
    }
}
