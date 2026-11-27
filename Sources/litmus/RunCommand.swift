import AnalyzerCLI
import ArgumentParser
import Foundation
import LitmusCore
import ReportSupport

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Build and test mutants in an owned snapshot. Executes trusted project code."
    )
    @OptionGroup var subject: SubjectOptions
    @OptionGroup var change: ChangeOptions
    @OptionGroup var build: BuildSelectionOptions
    @Option(help: "New run directory OUTSIDE the source tree; contains checkpoints, evidence and build artifacts.")
    var output: String
    @Option(help: "Maximum sites per schema build, 1...1024.") var batchSize: Int = 256
    @Option(help: "Build deadline in seconds, 1...86400.") var buildTimeout: Int = 900
    @Option(help: "Upper bound of the per-suite deadline in seconds; the deadline derives from the baseline.")
    var timeout: Int = 300
    @Option(help: "Deadline = baseline duration × this factor + 2 s (at least 3 s, at most --timeout).")
    var timeoutFactor: Int = 4
    @Option(help: "Mutants tested at once (default: CPUs − 1); Xcode and `swift test` run one.")
    var jobs: Int = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
    @Option(help: "Host package harness: automatic (direct bundles, parallel) or swift-test (one worker).")
    var harness: String = "automatic"
    @Option(help: "SwiftPM build system for host packages: native or swiftbuild (default: the toolchain's).")
    var swiftpmBuildSystem: String?
    @Flag(help: "Run every mutant's whole suite instead of stopping at its first Swift Testing failure.")
    var noFailFast = false
    @Option(help: "Kill confirmation: targeted (default: the failing tests alone, active and inactive), full, or none.")
    var killConfirmation: String = "targeted"
    @Flag(
        help:
            "Required: authorize executing package manifests, plugins, build scripts and tests. Copying is NOT an OS sandbox."
    ) var trustProject = false
    @Flag(help: "Retain the workspace after a completed run; failed runs are always retained.") var keepWorkspace =
        false
    @Option(
        help:
            "Simulators to test on at once for an Xcode run on an iOS Simulator, 1...16 (default 1: the destination itself). More are clones of it that Litmus makes, boots together and deletes at the end."
    )
    var simulators: Int = 1
    @Option(
        help:
            "Run only this test target for every mutant (repeatable), instead of selecting per mutant. The baseline still runs them all."
    )
    var testTarget: [String] = []
    @Flag(
        inversion: .prefixedNo,
        help: "One line on standard error per decided mutant (default: when standard error is a terminal)."
    )
    var progress: Bool = isatty(STDERR_FILENO) != 0
    @Flag(help: "Keep every Xcode result bundle (hundreds of MiB each on an app); only each run's summary otherwise.")
    var keepResultBundles = false
    @Option(help: "Memory limit of a test process and what it starts, in MiB; past it, a crash. 0: none.")
    var memoryLimit: Int = 4096
    @Flag(
        help:
            "Build and run first passes at background priority (2–15× slower); reruns that decide timeouts do not. A subject built with -warn-long-*-type-checking and warnings as errors may fail to build."
    )
    var background = false
    @Option(
        help: "Runs of the unmutated suite looking for flaky Swift Testing tests, which are then left out (1: none)."
    )
    var baselineRepetitions: Int = 3
    @Option(help: "Most Swift Testing tests one suite runs at once; workers are sized from it.")
    var suiteWidth: Int?
    @Flag(help: "Run every test module for every mutant, not only the test targets that can reach its file.")
    var noTestTargetSelection = false
    @Flag(
        inversion: .prefixedNo,
        help:
            "Narrow each mutant to the Swift Testing tests that reached it in the serial control pass (default: on; survivors are rechecked against every covering module)."
    )
    var perTestReach = true
    @Flag(help: "Skip re-verifying per-test-reach narrowed survivors against all covering test modules.")
    var noRecheckSurvivors = false
    @Option(help: "Seconds after which no schema build or first run starts; what did not run is reported, exit 0.")
    var budget: Int?
    @Option(help: "Run at most this many mutants, changed lines first; the rest are reported as not run.")
    var maxMutants: Int?
    @Option(
        name: .customLong("only-id"),
        help:
            "Run only this mutant (repeatable): its id, an id prefix of 8+ hex digits, or path:line[:operator]. Always executed, never reused."
    )
    var onlyID: [String] = []
    @Flag(help: "Run accepted mutants too, and report those a test now detects (their acceptance is stale).")
    var verifyAccepted = false
    @Flag(
        help:
            "Exclude test targets that fail unmutated instead of stopping (implied by --all-test-targets); mutants only they cover are reported as not run."
    )
    var skipFailingTargets = false
    @Flag(help: "Build and test the unmutated subject first, instead of using the first schema's inactive run.")
    var unmutatedBaseline = false
    @Option(
        help: "Result store directory (outside the root): verdicts reused when their key matches, stored as decided."
    )
    var resultStore: String?
    @Flag(help: "Read the result store, never write it (untrusted pull requests).") var storeReadOnly = false
    @Option(help: "Result store size bound in MiB; least recently used records are evicted past it.")
    var storeLimit: Int = 1024
    @Option(help: "Reuse keys: closure (sound: every input of the package and its local dependencies) or declaration.")
    var reuse: String = "closure"
    @Option(help: "Reuse the decided verdicts of an earlier run directory whose keys still match.")
    var resume: String?
    @Option(
        help:
            "A nightly run (its run.json, or its directory): its flaky tests and, where keys match, its per-test reach."
    )
    var reachFrom: String?
    @Option(help: "Run shard k of n (k/n): whole module units; put the shards together with `litmus merge`.")
    var shard: String?
    @Flag(help: "Run Xcode tests through xcodebuild only, not through Litmus's simulator helper for hostless bundles.")
    var noSimulatorHelper = false
    @Option(
        help:
            "auto (default): decide kills in a helper that keeps the test bundle loaded when it pays; on; off. macOS SwiftPM."
    )
    var sharedProcess: String = "auto"
    @Option(
        name: .customLong("xcodebuild-argument"),
        parsing: .unconditionalSingleValue,
        help: "An extra xcodebuild argument for builds and test runs (repeatable), e.g. -skipPackagePluginValidation."
    )
    var xcodebuildArguments: [String] = []
    @Option(help: "Print this report of the run on stdout instead of the artifact: xcode, json, sarif or markdown.")
    var report: String?
    @Option(help: "With --report: baseline file whose findings are left out (the base branch's, for the gate).")
    var baseline: String?
    @OptionGroup var limits: GateOptions
    @Option(help: "With --report: new-survivors fails on survivors the --baseline does not hold.")
    var gate: String?
    @Option(
        help:
            "copy (default: a fresh copy), persistent:<dir> (kept and synchronised: incremental builds), or in-place (CI: the checkout itself, originals backed up and restored)."
    )
    var workspace: String = "copy"
    @Option(
        help:
            "Directory holding Xcode's DerivedData (reuse a CI job's build); default: the run's or the persistent one."
    )
    var buildDirectory: String?
    /// Validates the options and maps them, once, to the driver and the runner options.
    func prepare() async throws -> (driver: BuildDriver, options: RunOptions) {
        guard trustProject else {
            throw ValidationError(
                "execution requires --trust-project; untrusted PRs need an isolated disposable runner"
            )
        }
        guard let selection = HarnessSelection(rawValue: harness == "swift-test" ? "swiftTest" : harness) else {
            throw ValidationError("harness must be automatic or swift-test")
        }
        var options = RunOptions()
        options.batchSize = batchSize
        options.buildTimeout = buildTimeout
        options.timeoutCap = timeout
        options.timeoutFactor = timeoutFactor
        options.jobs = jobs
        options.harness = selection
        options.failFast = !noFailFast
        guard let confirmation = KillConfirmation(rawValue: killConfirmation) else {
            throw ValidationError("kill-confirmation must be targeted, full or none")
        }
        options.killConfirmation = confirmation
        options.keepWorkspace = keepWorkspace
        options.memoryLimitMiB = memoryLimit
        options.background = background
        options.baselineRepetitions = baselineRepetitions
        options.suiteWidth = suiteWidth
        options.selectTestTargets = !noTestTargetSelection
        options.perTestReach = perTestReach
        options.recheckSurvivors = !noRecheckSurvivors
        options.budgetSeconds = budget
        options.maxMutants = maxMutants
        options.inactiveSchemaBaseline = !unmutatedBaseline
        options.resultStore = resultStore
        options.storeReadOnly = storeReadOnly
        options.storeLimitMiB = storeLimit
        options.resume = resume
        options.reachFrom = reachFrom.map(runArtifactPath)
        options.simulatorHarness = !noSimulatorHelper
        guard let mode = SharedProcessMode(rawValue: sharedProcess) else {
            throw ValidationError("--shared-process takes auto, on or off")
        }
        options.sharedProcess = mode
        options.allTestTargets = build.allTestTargets
        options.includeUITests = build.includeUITests
        options.skipFailingTargets = skipFailingTargets || build.allTestTargets
        options.acceptedFile = try subject.resolvedAcceptedFile()
        options.verifyAccepted = verifyAccepted
        do { options.onlyIDs = try onlyID.map(MutationSelector.init(parsing:)) } catch {
            throw ValidationError("\(error)")
        }
        do { options.shard = try shard.map(ShardSelection.init(parsing:)) } catch {
            throw ValidationError("\(error)")
        }
        guard let mode = ReuseContext.Mode(rawValue: reuse) else {
            throw ValidationError("reuse must be closure or declaration")
        }
        guard mode == .closure || (change.diff == nil && change.diffBase == nil) else {
            throw ValidationError("--reuse declaration is for whole-subject (nightly) runs, not --diff/--diff-base")
        }
        options.reuseMode = mode
        switch workspace {
        case "copy": options.workspace = .copy
        case "in-place": options.workspace = .inPlace
        case let value where value.hasPrefix("persistent:") && value.count > "persistent:".count:
            let directory = String(value.dropFirst("persistent:".count))
            options.workspace = .persistent(URL(fileURLWithPath: directory).standardizedFileURL.path)
        default: throw ValidationError("workspace must be copy, in-place or persistent:<dir>")
        }
        options.buildDirectory = buildDirectory.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        guard swiftpmBuildSystem.map({ ["native", "swiftbuild"].contains($0) }) ?? true else {
            throw ValidationError("swiftpm-build-system must be native or swiftbuild")
        }
        var driver: BuildDriver
        do { driver = try build.driver(root: subject.absoluteRoot) } catch { try fail(error, code: .usage) }
        driver.swiftPMBuildSystem = swiftpmBuildSystem
        driver.xcodebuildArguments = xcodebuildArguments
        guard report.map({ ["xcode", "json", "sarif", "markdown"].contains($0) }) ?? true else {
            throw ValidationError("report must be xcode, json, sarif or markdown")
        }
        guard gate == nil || (gate == "new-survivors" && baseline != nil && report != nil) else {
            throw ValidationError("--gate new-survivors needs --report and --baseline")
        }
        if !driver.usesXcode
            && !FileManager.default.fileExists(
                atPath: driver.executionDirectory(workspace: subject.absoluteRoot) + "/Package.swift"
            )
        {
            throw ValidationError(
                "host package requires Package.swift; Xcode projects need --project, --scheme and --destination"
            )
        }
        options.exclude = try subject.excludes()
        options.include = try subject.includes()
        options.aridCalls = try subject.resolvedAridCalls()
        options.excludeDeclarations = try subject.resolvedExcludeDeclarations()
        options.operators = try subject.operatorSet()
        options.simulators = simulators
        options.progress = progress
        options.testTargets = testTarget
        options.keepResultBundles = keepResultBundles
        do { options.scope = try await change.scope(root: subject.absoluteRoot, reach: reachFrom) } catch let error
            as ValidationError
        {
            throw error
        } catch { try fail(error, code: .usage) }
        return (driver, options)
    }

    mutating func run() async throws {
        let (driver, options) = try await prepare()
        let artifact: RunArtifact
        let (runDriver, runOptions, runOutput) = (driver, options, output)
        do {
            // A signal cancels the run: its children are ended and its checkpoint written.
            artifact = try await TerminationSignals.run {
                try await MutationRunner(executor: BoundedExecutor()).run(
                    driver: runDriver,
                    outputDirectory: runOutput,
                    options: runOptions
                )
            }
        } catch let interrupted as TerminationSignals.Interrupted {
            stderr("litmus: interrupted by signal \(interrupted.signal); partial evidence at \(output)/run.json")
            throw ExitCode(interrupted.exitStatus)
        } catch { try fail(error, code: .internalFailure) }
        if let report {
            // One step for CI (Danger runs one command per analyzer): the run, then its report as `analyze` gives it.
            try await printReport(artifact, format: report)
        } else {
            print(String(decoding: try ArtifactCodec.json(artifact), as: UTF8.self))
        }
        if let scope = artifact.plan.scope, artifact.results.isEmpty {
            stderr(
                "litmus: \(scope.source): \(scope.swiftFiles) changed Swift file(s), no mutable site in scope; "
                    + "nothing built or run (\(((artifact.timings["total"] ?? 0) * 100).rounded() / 100) s)"
            )
            return
        }
        let counts = Dictionary(grouping: artifact.results, by: \.verdict).mapValues(\.count)
        let summary = Verdict.allCases.compactMap { verdict in counts[verdict].map { "\(verdict.rawValue) \($0)" } }
        let score = artifact.score.percent.map { String($0) + "%" } ?? "n/a"
        stderr(
            "litmus: \(artifact.results.count) mutants: \(summary.joined(separator: ", ")); score \(score); "
                + "\(((artifact.timings["total"] ?? 0) * 10).rounded() / 10) s; evidence at \(output)/run.json"
        )
        if let reused = artifact.reuse, reused.resumed + reused.fromStore > 0 {
            stderr("litmus: \(reused.resumed + reused.fromStore) verdict(s) reused (\(reused.mode.rawValue) keys)")
        }
        if let budget = artifact.budget, let stopped = budget.stoppedBy {
            let why =
                stopped == "failing-test-target"
                ? "only test targets that failed unmutated cover them" : "the \(stopped) limit was reached"
            stderr("litmus: \(budget.untested.count) mutant(s) not run: \(why)")
        }
        if let cost = artifact.cost {
            stderr(
                "litmus: cost: \(cost.builds) build(s), \(cost.testRuns) test run(s), CPU \(cost.childCPUSeconds) s "
                    + "(children) + \(cost.litmusCPUSeconds) s, peak memory \(cost.childPeakRSSMiB) MiB (largest child), "
                    + "disk \(cost.runDirectoryMiB) MiB"
            )
        }
        if !artifact.isSuccessfulExecution { throw ExitCode(ExitStatus.internalFailure.rawValue) }
        let belowGate = try limits.fails(artifact)
        if reportFindings || belowGate { throw ExitCode(ExitStatus.findings.rawValue) }
    }

    /// Whether the report printed findings that fail the run (errors, and warnings under the gate).
    private var reportFindings = false

    private mutating func printReport(_ artifact: RunArtifact, format: String) async throws {
        var accepted: Set<String> = []
        if let baseline, FileManager.default.fileExists(atPath: baseline) {
            do {
                let file = try ArtifactCodec.decode(
                    BaselineFile.self,
                    bytes: Array(try Data(contentsOf: URL(fileURLWithPath: baseline)))
                ).validated(requiringVersion: true)
                accepted = Set(file.fingerprints)
            } catch { try fail(error, code: .badConfiguration) }
        } else if let baseline {
            // No base baseline yet (no nightly has run): every finding is new, as without one.
            stderr("litmus: no baseline at \(baseline); every finding counts as new")
        }
        let root = subject.absoluteRoot
        let made: MutationReport
        do {
            // Absolute paths: a CI tool that runs Litmus on one package of a repository makes them its own.
            made = try await MutationReport.make(artifact, root: root, relative: false, baseline: accepted)
        } catch { try fail(error, code: .internalFailure) }
        do {
            switch format {
            case "markdown": print(MarkdownReport.render(made, artifact: artifact), terminator: "")
            default: print(try LitmusReportFormat.render(made, format: format, root: nil))
            }
        } catch { try fail(error, code: .outputFailure) }
        reportFindings = made.findings.contains { $0.severity == "error" || gate != nil && $0.severity == "warning" }
    }
}
