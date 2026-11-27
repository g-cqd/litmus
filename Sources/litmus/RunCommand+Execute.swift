import AnalyzerCLI
import ArgumentParser
import Foundation
import LitmusCore
import ReportSupport

extension Run {
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
        options.indexStorePath = subject.indexStorePath
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

    mutating func printReport(_ artifact: RunArtifact, format: String) async throws {
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
