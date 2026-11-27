internal import Foundation
internal import SourceCorpus

extension RunSession {
    /// The fast path: a change reaching no site ends here, before any copy, build or toolchain query.
    func scopeFastPath() async throws -> RunArtifact? {
        guard let scope = options.scope else { return nil }
        // The fast path: a change reaching no site ends here, before any copy, build or toolchain query.
        let sourcePlan = try await MutationPlanner.plan(
            root: root,
            exclude: options.exclude,
            include: options.include,
            packagePath: driver.packagePath,
            jobs: 8,
            scope: scope,
            operators: options.operators,
            aridCalls: options.aridCalls,
            excludeDeclarations: options.excludeDeclarations,
            indexedRoot: root,
            indexStorePath: options.indexStorePath
        )
        account("plan", since: phase)
        if sourcePlan.mutations.isEmpty {
            phase = clock.now
            let inputs = try await WorkspaceSnapshot.currentEntries(root)
            account("inventory", since: phase)
            let provenance = RunProvenance(
                toolVersion: LitmusVersion.current,
                snapshotSHA256: Digest.sha256(try ArtifactCodec.json(inputs)),
                inputs: inputs,
                driver: driver,
                toolchain: "not invoked: the change reaches no mutable site",
                startedAt: ISO8601DateFormatter().string(from: Date()),
                executionPolicy: RunArtifact.executionPolicy
            )
            var artifact = RunArtifact(provenance: provenance, plan: sourcePlan)
            artifact.notes.append(
                "\(scope.source): \(sourcePlan.scope?.swiftFiles ?? 0) changed Swift file(s), no mutable site on "
                    + (scope.breadth == .lines ? "their changed lines" : "them")
                    + "; nothing was copied, built or run"
            )
            artifact.complete = true
            timings["total"] = seconds(clock.now - started)
            artifact.timings = timings
            artifact.cost = cost(workspace: nil)
            try ArtifactCodec.write(artifact, path: output + "/run.json")
            try ArtifactCodec.write(artifact, path: output + "/run.pb")
            return artifact
        }
        return nil
    }

    /// Creates the owned workspace the run builds and mutates in.
    func prepareWorkspace() async throws {
        prepared = try await PreparedWorkspace.prepare(
            options.workspace,
            source: root,
            output: output,
            buildDirectory: options.buildDirectory.map(canonicalNew)
        )
        snapshot = prepared.snapshot
        artifacts = prepared.buildDirectory
        try FileManager.default.createDirectory(atPath: artifacts, withIntermediateDirectories: true)
    }

    /// Ends the workspace: restores what is still rewritten (in place), releases the lock.
    func releaseWorkspace() {
        guard !workspaceReleased else { return }
        workspaceReleased = true
        if let journal = prepared.restore {
            _ = try? journal.restoreAll()
            prepared.lock?.release()
            journal.tidy()
        } else {
            prepared.lock?.release()
        }
    }

    /// Builds the workspace as it stands; throws when an unmutated build fails.
    /// Builds the workspace as it stands; throws when an unmutated build fails.
    func buildUnmutated() async throws {
        phase = clock.now
        counter.build()
        let baselineBuild = try await executor.execute(
            driver.buildCommand(workspace: snapshot.root, artifacts: artifacts),
            directory: driver.executionDirectory(workspace: snapshot.root),
            environment: subjectEnvironment(nil),
            timeout: options.buildTimeout,
            supervision: buildSupervision
        )
        try writeLog(baselineBuild, path: logs + "/baseline-build.log")
        account("build", since: phase)
        guard baselineBuild.exitStatus == 0, !baselineBuild.timedOut else {
            let first = CompilerDiagnostics(baselineBuild, snapshotRoot: snapshot.root).errors.first
            let detail =
                first.map { ": \($0.path):\($0.line): \($0.message)" }
                ?? CompilerDiagnostics.firstError(baselineBuild).map { ": \($0)" } ?? ""
            let hint =
                options.background
                ? "; at --background priority a type-check time limit of the subject's can fail it (rerun without)"
                : ""
            throw LitmusFailure(
                "unmutated build failed\(detail)\(hint); no mutant verdicts are valid (logs/baseline-build.log)"
            )
        }
    }

    /// Ends the run: complete, timed, costed, the workspace removed unless kept.
    func finish() throws -> RunArtifact {
        artifact.complete = true
        if let acceptance = plan.acceptance, !acceptance.accepted.isEmpty {
            artifact.notes.append(
                "\(acceptance.accepted.count) mutant(s) accepted in \(acceptance.file)"
                    + (acceptance.verifying ? ", run anyway" : ", not run")
            )
        }
        for id in artifact.staleKilledAcceptances {
            artifact.notes.append("stale-killed: accepted mutant \(id) is now detected; run `litmus unaccept \(id)`")
        }
        if let store {
            let removed = store.evict()
            artifact.notes += store.notes
            if removed > 0 {
                artifact.notes.append("result store: \(removed) least recently used record(s) evicted")
            }
        }
        timings["total"] = seconds(clock.now - started)
        artifact.timings = timings
        artifact.cost = cost(workspace: prepared.removable ? snapshot.root : nil)
        if let journal = prepared.restore {
            // In place: nothing may stay rewritten, and every mutated file must hold its original bytes again.
            try journal.restoreAll()
            let mutated = Set(plan.mutations.map(\.path))
            let expected = Dictionary(
                snapshot.entries.map { ($0.path, $0.sha256) },
                uniquingKeysWith: { a, _ in a }
            )
            for path in mutated.sorted() {
                let bytes = try BoundedFileReader.read(path: root + "/" + path, cap: 64 << 20)
                guard Digest.sha256(bytes) == expected[path] else {
                    throw LitmusFailure("in place: \(path) does not hold its original bytes after the run")
                }
            }
            artifact.notes.append("in place: \(mutated.count) mutated file(s) restored and verified")
        }
        releaseWorkspace()
        if !options.keepWorkspace {
            // Every verdict is recorded: remove transient workspace, workers and run-owned build artifacts (a user's
            // `--build-directory` or persistent workspace is never touched). A directory that cannot be removed
            // (Finder or Spotlight writing into it while it goes) is noted, never a failed run.
            let ownedArtifacts = (prepared.removable && options.buildDirectory == nil) ? [artifacts] : []
            for directory in (prepared.removable ? [snapshot.root] : []) + ownedArtifacts + [workers]
            where !Runner.remove(directory) {
                artifact.notes.append("could not remove \(directory); delete it by hand")
            }
        }
        try ArtifactCodec.write(artifact, path: checkpointPath)
        try ArtifactCodec.write(artifact, path: output + "/run.pb")
        return artifact
    }
}
