internal import AemiIO
internal import AemiJSON
internal import AemiRuntime
internal import Foundation
internal import ProjectModel
internal import SourceCorpus

/// Which test harness a host package uses.
public enum HarnessSelection: String, Codable, Sendable {
    /// Built bundles run directly, in parallel, falling back to `swift test` when the layout is not understood.
    case automatic
    /// `swift test` per execution: one worker, slowest, fewest assumptions.
    case swiftTest
}

/// How a mutant's first failing run becomes a kill.
public enum KillConfirmation: String, Codable, Sendable {
    /// The first failure after activation is the kill. Fastest; a load-sensitive test can make false kills.
    case none
    /// The failing tests are rerun alone, with the mutant active (they must fail and reach it) and inactive (they must
    /// pass). Without test identities (XCTest, `swift test`, Xcode), the whole suite is rerun alone instead.
    case targeted
    /// An inactive whole-suite control and a second active whole-suite run, alone.
    case full
}

/// Execution options; every bound is checked before anything runs.
public struct RunOptions: Sendable {
    public var exclude: [String] = []
    /// When not empty, only files matching these substrings or globs are mutated.
    public var include: [String] = []
    /// Calls neither removed by `remove-call` nor mutated inside their arguments (`aridCalls` / `--arid-call`).
    public var aridCalls: [String] = []
    /// Declarations whose bodies are not mutated (`excludeDeclarations` / `--exclude-declaration`).
    public var excludeDeclarations: [String] = []
    /// Maximum sites per schema build, 1...1024 (default 256 with bounded expression nesting).
    /// The operators mutated; the stable tier unless a run asks for more.
    public var operators = MutationOperator.defaults
    /// Simulators to test on at once, for an Xcode run on an iOS Simulator: Litmus makes this many (clones of the
    /// destination, booted together) and deletes them at the end. One uses the destination itself.
    public var simulators = 1
    /// Keep every Xcode result bundle; only each run's summary otherwise.
    public var keepResultBundles = false
    /// Test modules every mutant runs, instead of all of them (and instead of the per-mutant selection); empty runs
    /// them all.
    public var testTargets: [String] = []
    /// One line on standard error per decided mutant.
    public var progress = false
    public var batchSize = 256
    /// Deadline of one build, in seconds.
    public var buildTimeout = 900
    /// Upper bound of the per-suite deadline, in seconds; the deadline itself derives from the baseline.
    public var timeoutCap = 300
    /// Deadline = max(`minimumTimeout`, baseline × `timeoutFactor` + 2 s), at most `timeoutCap`.
    public var timeoutFactor = 4
    public var minimumTimeout = 3
    /// Mutants tested at once when the harness allows it.
    public var jobs = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
    public var harness: HarnessSelection = .automatic
    /// Stop a mutant's suite at its first structured failure (Swift Testing event stream).
    public var failFast = true
    /// How a first failing run is confirmed (the fcheck pilot found load-sensitive tests making false kills).
    public var killConfirmation = KillConfirmation.targeted
    public var keepWorkspace = false
    /// The most memory one test process and what it starts may use, in MiB; past it the run is stopped and counts as
    /// a crash (a mutant that allocates without bound). 0: no limit.
    public var memoryLimitMiB = 4096
    /// Run builds and first runs at background priority, to leave a shared machine usable. Reruns, which decide
    /// timeouts, run at the normal priority: background stretches wall time 2 to 15 times (measured).
    public var background = false
    /// Runs of the unmutated suite looking for flaky Swift Testing tests (`--repetitions`); a test that fails in any is
    /// left out of every later run. 1: no probe.
    public var baselineRepetitions = 3
    /// The most Swift Testing tests one suite runs at once; workers are then sized from it. Nil: the suite decides.
    public var suiteWidth: Int?
    /// Run, for each mutant, only the test targets that can reach its file (from the manifests, without building).
    public var selectTestTargets = true
    /// Record which Swift Testing tests reach which mutants (`RunArtifact.perTestReach`) in a single serial control
    /// pass via an event-stream FIFO, narrowing each mutant's execution to its reaching tests.
    public var perTestReach = false
    /// Re-verify mutants that survived a `perTestReach`-narrowed run against all covering test modules so shared-state
    /// interactions across tests never produce a false survivor.
    public var recheckSurvivors = true
    /// The change a pull-request run is limited to (`--diff`, `--diff-base`); nil mutates the whole subject.
    public var scope: ChangeScope?
    /// Stop starting schema builds and first runs after this many seconds; what did not run is reported as such.
    public var budgetSeconds: Int?
    /// Run at most this many mutants (in plan order: changed lines first); the rest are reported as not run.
    public var maxMutants: Int?
    /// The first schema that builds is the baseline (its inactive run); false builds and tests the unmutated subject
    /// first, as before 0.3 (`--unmutated-baseline`).
    public var inactiveSchemaBaseline = true
    /// A result store directory: verdicts are looked up before running and stored as decided.
    public var resultStore: String?
    public var storeReadOnly = false
    public var storeLimitMiB = 1024
    /// How reuse keys cover the code (`--reuse`); `.declaration` only for nightly runs.
    public var reuseMode = ReuseContext.Mode.closure
    /// An earlier run directory whose decided verdicts are reused when their keys match (`--resume`).
    public var resume: String?
    /// A nightly run whose flaky tests are reused (the probe is skipped) and whose per-test reach is used for the
    /// mutants whose reuse keys still match (`--reach-from`, t49).
    public var reachFrom: String?
    /// Run one shard of the plan (`--shard k/n`): whole module units, merged later with `litmus merge`.
    public var shard: ShardSelection?
    /// Run hostless Xcode test bundles on the simulator through Litmus's helper rather than `xcodebuild`.
    public var simulatorHarness = true
    /// Where the run builds and mutates (`--workspace`).
    public var workspace = WorkspaceStrategy.copy
    /// The directory holding Xcode's `DerivedData` (`--build-directory`); default: the run's or the persistent one.
    public var buildDirectory: String?

    public init() {}

    /// The supervision every test and build process gets.
    func supervision(background: Bool? = nil) -> Supervision {
        var supervision = Supervision()
        supervision.memoryLimitBytes = memoryLimitMiB > 0 ? UInt64(memoryLimitMiB) << 20 : nil
        supervision.sampling = memoryLimitMiB > 0 ? .milliseconds(100) : nil
        supervision.background = background ?? self.background
        return supervision
    }

    func validate() throws {
        guard (1...1024).contains(batchSize), (1...86_400).contains(buildTimeout), (1...86_400).contains(timeoutCap),
            (1...100).contains(timeoutFactor), (1...86_400).contains(minimumTimeout), minimumTimeout <= timeoutCap,
            (1...256).contains(jobs), (1...16).contains(simulators), (0...1_048_576).contains(memoryLimitMiB),
            (1...100).contains(baselineRepetitions),
            suiteWidth.map({ (1...256).contains($0) }) ?? true,
            budgetSeconds.map({ (1...604_800).contains($0) }) ?? true, maxMutants.map({ $0 >= 1 }) ?? true,
            (1...1_048_576).contains(storeLimitMiB)
        else {
            throw LitmusFailure(
                "batch size, deadlines, jobs, memory, repetitions, width, budget or store limit outside documented bounds"
            )
        }
    }
}
