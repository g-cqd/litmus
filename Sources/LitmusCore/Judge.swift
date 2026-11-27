internal import AemiRuntime
internal import Foundation

/// Runs and classifies mutants against the current build.
struct Judge: Sendable {
    let harness: any TestHarness

    let pool: ResourcePool<WorkerSlot>

    let options: RunOptions

    let counter: RunCounter

    let baseline: TestCounts

    let deadline: Int

    /// The deadline of a mutant's first run among parallel workers: contention slows every suite.
    let parallelDeadline: Int

    let rerunDeadline: Int

    /// Swift Testing tests left out of every run: they failed in the unmutated suite's repetitions.
    var skip: [String] = []

    /// For each mutant, the test modules that can reach its file; a mutant without an entry runs every module.
    var covering: [String: Set<String>] = [:]

    /// The unmutated suite's counts per module, what a mutant's selected modules must pass.
    var baselineByModule: [String: TestCounts] = [:]

    /// For each mutant whose per-test reach is known (this run's `--per-test-reach`, or a matching `--reach-from`):
    /// the Swift Testing tests that reach it when run alone, no mutant active (t37, t38).
    var reach: [String: Set<String>] = [:]

    /// Each test's counts when it ran alone (with per-test reach): what a run of selected tests must pass.
    var testCounts: [String: TestCounts] = [:]

    /// Test modules quarantined for failing unmutated (`--skip-failing-targets`): never run.
    var quarantined: Set<String> = []

    /// This run's finished mutant runs, which shorten later deadlines; shared by every copy of the judge.
    var timings = MutantTimings()

    /// The reaching tests a mutant's runs are limited to: known, not empty, every count known; nil runs the modules.
    func selected(_ site: Mutation) -> [String]? {
        guard harness.selectsTests, let tests = reach[site.id], !tests.isEmpty,
            tests.allSatisfy({ testCounts[$0] != nil })
        else { return nil }
        return tests.sorted()
    }

    /// The counts a passing run of `site` must have: its reaching tests', its selected modules', or the baseline's.
    func expected(_ site: Mutation) -> TestCounts {
        if let tests = selected(site) { return Self.passing(tests.map { testCounts[$0] }) }
        guard let modules = covering[site.id] else { return baseline }
        return Self.passing(modules.map { baselineByModule[$0] })
    }

    /// The passed and skipped counts of `parts` added up, with no failure; an unknown part counts nothing.
    static func passing(_ parts: [TestCounts?]) -> TestCounts {
        TestCounts(
            passed: parts.reduce(0) { $0 + ($1?.passed ?? 0) },
            failed: 0,
            skipped: parts.reduce(0) { $0 + ($1?.skipped ?? 0) }
        )
    }

    struct Execution {
        let result: TestRunResult
        let reached: Set<String>
    }

    struct Decision: Sendable {
        let site: Mutation
        let verdict: Verdict
        let reason: String
        let evidence: [String]
        let nanoseconds: Int64
        let tests: TestCounts?
    }

    /// What a mutant's first, parallel run decided, or the rerun it needs.
    enum Step: Sendable {
        case done(Decision)
        /// A failure without activation, a crash, a timeout, or a kill to confirm: rerun after the parallel pass, alone.
        case rerun(Pending)
        /// Not started: the time budget ran out first.
        case notStarted(Mutation)
    }

    struct Pending: Sendable {
        let site: Mutation
        let outcome: TestRunOutcome
        let activated: Bool
        let failingTests: [String]
        let evidence: [String]
        let nanoseconds: Int64
    }
}
