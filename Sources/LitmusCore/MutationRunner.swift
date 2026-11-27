internal import Foundation
internal import SourceCorpus

/// Builds conflict-free schemas once per batch, isolates mutants that do not compile, measures which mutants the
/// suite reaches, and tests the reached ones in parallel.
///
/// Policy (`RunArtifact.executionPolicy`):
/// - The unmutated build and suite must pass; every schema's inactive control must pass with the baseline's counts.
/// - A mutant the control never reached is `noCoverage`, without running it.
/// - A failure counts only when the mutant's own marker shows its code ran; a failure without activation is rerun
///   alone, and stays an infrastructure error if it repeats.
/// - A crash is rerun alone and counts when it repeats; a timeout is rerun alone with twice the deadline.
/// - A schema that does not compile is split by its compiler diagnostics, then by halves, until each mutant that does
///   not compile alone is `unviable`.
/// - An inactive control that differs from the baseline is retried once; if it differs again its batch is split by
///   halves (within a budget) until the mutant that breaks it is alone, and only that one is an infrastructure error.
public struct MutationRunner<Executor: ProcessExecutor>: Sendable {
    let executor: Executor

    public init(executor: Executor) { self.executor = executor }

    /// Creates an owned snapshot, reuses what cannot have changed, validates the baseline, then decides every site
    /// the budget allows.
    /// - Important: Only run on trusted project code; copying is not a security sandbox.
    /// - Throws: On baseline failure, cancellation or artifact/I/O failure; the checkpoint and the journal keep the
    ///   decisions made so far.
    public func run(driver: BuildDriver, outputDirectory: String, options: RunOptions = RunOptions()) async throws
        -> RunArtifact
    {
        try await RunSession(
            runner: self,
            executor: executor,
            driver: driver,
            outputDirectory: outputDirectory,
            options: options
        ).run()
    }

    /// What one baseline established: the judge, its counts and deadlines, and the baseline execution itself (the
    /// control of the first schema when that schema was the baseline).
    struct Established {
        let judge: Judge
        let counts: TestCounts
        let deadline: Int
        let workerCount: Int
        let testFunctions: [String]
        let baseline: Judge.Execution
    }

    /// Where a decision goes: the run's journal, and the result store when there is one.
    struct Sink {
        let journal: ResultJournal
        let store: ResultStore?
        let runID: String
        var progress: ProgressReporter? = nil
    }

    /// The resolved verdicts of an earlier run (`--resume`), by reuse key: its checkpoint, then its journal (later
    /// decisions win; a frame cut short by a crash is ignored). Evidence paths are made absolute to that run.
    static func previousResults(runDirectory: String) throws -> [String: ReusedResult] {
        let directory = SourcePath.canonical(runDirectory)
        let artifact = try ArtifactCodec.read(RunArtifact.self, path: directory + "/run.json")
        var results = artifact.results
        let journalPath = directory + "/results.journal"
        if FileManager.default.fileExists(atPath: journalPath) {
            results += try ResultJournal.read(path: journalPath).results
        }
        var byKey: [String: ReusedResult] = [:]
        for var result in results {
            guard let key = result.reuseKey, result.verdict.isResolved else { continue }
            if result.reusedFrom == nil {
                result = MutationResult(
                    mutation: result.mutation,
                    verdict: result.verdict,
                    tests: result.tests,
                    reason: result.reason,
                    evidence: result.evidence.map { $0.hasPrefix("/") ? $0 : directory + "/" + $0 },
                    nanoseconds: result.nanoseconds
                )
            }
            byKey[key] = ReusedResult(result: result, runID: artifact.provenance.runID)
        }
        return byKey
    }

    /// How long each mutant took in an earlier run (`run.json` and its journal), by mutation id: ids are anchored to
    /// the code, so they outlive the edits that change a verdict's reuse key.
    static func previousDurations(runDirectory: String) -> [String: Int64] {
        let directory = SourcePath.canonical(runDirectory)
        var results = (try? ArtifactCodec.read(RunArtifact.self, path: directory + "/run.json"))?.results ?? []
        if let journal = try? ResultJournal.read(path: directory + "/results.journal") { results += journal.results }
        var durations: [String: Int64] = [:]
        for result in results where result.nanoseconds > 0 { durations[result.mutation.id] = result.nanoseconds }
        return durations
    }

    /// Records `sites` as not run within the budget.
    func untested(
        _ sites: [Mutation],
        _ reason: String,
        stoppedBy: String,
        into artifact: inout RunArtifact,
        _ sink: Sink
    ) throws {
        guard !sites.isEmpty else { return }
        for site in sites { try record(site, .notRun, reason, [], into: &artifact, sink) }
        var budget = artifact.budget ?? BudgetRecord()
        budget.stoppedBy = budget.stoppedBy ?? stoppedBy
        budget.untested += sites.map(\.id)
        artifact.budget = budget
    }

    func record(_ decision: Judge.Decision, into artifact: inout RunArtifact, _ sink: Sink) throws {
        try record(
            decision.site,
            decision.verdict,
            decision.reason,
            decision.evidence,
            nanoseconds: decision.nanoseconds,
            tests: decision.tests,
            into: &artifact,
            sink
        )
    }

    func record(
        _ site: Mutation,
        _ verdict: Verdict,
        _ reason: String,
        _ evidence: [String],
        nanoseconds: Int64 = 0,
        tests: TestCounts? = nil,
        into artifact: inout RunArtifact,
        _ sink: Sink
    ) throws {
        try record(
            MutationResult(
                mutation: site,
                verdict: verdict,
                tests: tests,
                reason: reason,
                evidence: evidence,
                nanoseconds: nanoseconds
            ),
            into: &artifact,
            sink
        )
    }

    /// Replaces the planned mutant's result, journals it, and stores it when it was decided now and resolved.
    func record(_ result: MutationResult, into artifact: inout RunArtifact, _ sink: Sink) throws {
        guard let index = artifact.results.firstIndex(where: { $0.mutation.id == result.mutation.id }) else {
            throw LitmusFailure("internal: result for unplanned mutant \(result.mutation.id)")
        }
        var result = result
        result.reuseKey = artifact.results[index].reuseKey
        artifact.results[index] = result
        try sink.journal.append(result)
        sink.progress?.report(result)
        if let store = sink.store, let key = result.reuseKey, result.reusedFrom == nil {
            // A cache: a record that cannot be written is a later miss, never a failed run.
            do { try store.put(key, result, runID: sink.runID) } catch {
                artifact.notes.append("result store: \(result.mutation.id) not stored: \(error)")
            }
        }
    }

    /// Refuses an in-place run when a file to mutate is untracked or modified in git: then `git checkout` could not be
    /// the last resort that restores it.
    func requireCleanGit(_ paths: [String], root: String) async throws {
        func git(_ arguments: [String]) async throws -> ProcessOutput {
            try await executor.execute(
                ToolCommand(executable: "/usr/bin/xcrun", arguments: ["git"] + arguments),
                directory: root,
                environment: subjectEnvironment(nil),
                timeout: 120
            )
        }
        let tracked = try await git(["ls-files", "--error-unmatch", "--"] + paths)
        guard tracked.exitStatus == 0 else {
            throw LitmusFailure("--workspace in-place needs a git work tree whose files to mutate are all tracked")
        }
        let status = try await git(["status", "--porcelain=v1", "--"] + paths)
        guard status.exitStatus == 0, !status.truncated, status.stdout.isEmpty else {
            let changed = String(decoding: status.stdout.prefix(400), as: UTF8.self)
            throw LitmusFailure(
                "--workspace in-place needs the files to mutate unmodified (commit or stash first): \(changed)"
            )
        }
    }
}

func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}
