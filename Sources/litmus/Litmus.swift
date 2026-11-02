import AnalyzerCLI
import ArgumentParser
import Foundation
import LitmusCore

@main struct Litmus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Evidence-led mutation testing for Swift packages and Xcode projects.",
        version: LitmusVersion.current,
        subcommands: [Plan.self, Run.self, Analyze.self, Census.self, Restore.self]
    )
}

private struct SubjectOptions: ParsableArguments {
    @Argument(help: "Subject root containing all local dependencies; never modified by Litmus.") var root: String = "."
    @Option(help: "Configuration file: exclude, and include in .litmus.json or the litmus section.") var config: String?
    @Option(name: .customLong("exclude-path"), help: "Exclude a substring/glob from mutation discovery (repeatable).")
    var exclusions: [String] = []
    @Option(name: .customLong("only-path"), help: "Mutate only files matching a substring/glob (repeatable).")
    var inclusions: [String] = []
    var absoluteRoot: String { URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path }
    func excludes() throws -> [String] {
        do { return try LitmusConfiguration.load(root: absoluteRoot, explicit: config).exclude + exclusions } catch {
            try fail(error, code: .badConfiguration)
        }
    }
    func includes() throws -> [String] {
        do { return try LitmusConfiguration.load(root: absoluteRoot, explicit: config).include + inclusions } catch {
            try fail(error, code: .badConfiguration)
        }
    }
}

/// What a pull-request run mutates (ADR 0007).
private struct ChangeOptions: ParsableArguments {
    @Option(help: "Limit to the change in this unified diff (paths relative to --diff-root).") var diff: String?
    @Option(
        help:
            "Limit to the change from the merge base with this revision to the working tree (git; tracked files only)."
    )
    var diffBase: String?
    @Option(help: "Directory the --diff paths are relative to (default: the enclosing git work tree, else the root).")
    var diffRoot: String?
    @Option(help: "Leading path components to strip from --diff paths (default: detect git's a/ and b/).")
    var diffStrip: Int?
    @Option(help: "lines: sites on changed lines; files: every site of changed files, changed lines first.")
    var diffScope: String = "lines"

    func scope(root: String) async throws -> ChangeScope? {
        guard diff == nil || diffBase == nil else { throw ValidationError("--diff and --diff-base are exclusive") }
        guard let breadth = ChangeScope.Breadth(rawValue: diffScope) else {
            throw ValidationError("diff-scope must be lines or files")
        }
        if let diff {
            return try ChangeScope.load(
                diffFile: diff,
                root: root,
                diffRoot: diffRoot.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path },
                strip: diffStrip,
                breadth: breadth
            )
        }
        if let diffBase {
            return try await ChangeScope.fromGit(
                base: diffBase,
                root: root,
                breadth: breadth,
                executor: BoundedExecutor()
            )
        }
        return nil
    }
}

private struct Plan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Discover syntax mutation candidates without building or executing project code."
    )
    @OptionGroup var subject: SubjectOptions
    @OptionGroup var change: ChangeOptions
    @Option(help: "Output plan (.json or .pb); stdout JSON when omitted.") var output: String?
    @Option(help: "Bounded source-discovery parallelism, 1...16.") var jobs: Int = 4
    mutating func run() async throws {
        guard (1...16).contains(jobs) else { throw ValidationError("jobs must be 1...16") }
        let excludes = try subject.excludes()
        let plan: MutationPlan
        do {
            plan = try await MutationPlanner.plan(
                root: subject.absoluteRoot,
                exclude: excludes,
                include: try subject.includes(),
                jobs: jobs,
                scope: try await change.scope(root: subject.absoluteRoot)
            )
        } catch let error as ValidationError {
            throw error
        } catch {
            try fail(error, code: .usage)
        }
        do {
            if let output {
                try ArtifactCodec.write(plan, path: output)
            } else {
                print(String(decoding: try ArtifactCodec.json(plan), as: UTF8.self))
            }
        } catch { try fail(error, code: .outputFailure) }
        stderr(
            "litmus: \(plan.mutations.count) candidates, \(plan.suppressed.count) suppressed in \(plan.analyzedFiles) files; plan is not test evidence"
        )
        if plan.notes.contains(where: \.isDegraded) { throw ExitCode(ExitStatus.internalFailure.rawValue) }
    }
}

private struct Census: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Count where candidate operators would apply (syntax only; sizes operators before they exist)."
    )
    @OptionGroup var subject: SubjectOptions
    @Option(help: "json or text.") var format: String = "text"
    mutating func run() async throws {
        guard ["json", "text"].contains(format) else { throw ValidationError("format must be json or text") }
        let report: CensusReport
        do { report = try await MutationCensus.run(root: subject.absoluteRoot, exclude: try subject.excludes()) } catch
        {
            try fail(error, code: .usage)
        }
        if format == "json" {
            print(String(decoding: try ArtifactCodec.json(report), as: UTF8.self))
            return
        }
        print(
            "production files \(report.files), excluded \(report.excludedFiles), degraded \(report.degradedFiles.count)"
        )
        for entry in report.entries {
            print(
                "\(entry.operatorID)\t\(entry.shape.rawValue)\tsites \(entry.sites)\tmutants \(entry.mutants)\tblocked \(entry.blocked)"
            )
        }
    }
}

private struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Build and test mutants in an owned snapshot. Executes trusted project code."
    )
    @OptionGroup var subject: SubjectOptions
    @OptionGroup var change: ChangeOptions
    @Option(help: "Relative .xcodeproj/.xcworkspace inside root. Omit for Swift packages.") var project: String?
    @Option(help: "Xcode scheme (required for iOS packages/projects).") var scheme: String?
    @Option(help: "Xcode destination (supply an existing simulator ID for reproducibility).") var destination: String?
    @Option(help: "New run directory OUTSIDE the source tree; contains checkpoints, evidence and build artifacts.")
    var output: String
    @Option(help: "Maximum non-overlapping sites per schema, 1...256.") var batchSize: Int = 64
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
    @Flag(help: "Record which Swift Testing tests reach which mutants, running each test alone per schema (slow).")
    var perTestReach = false
    @Option(help: "Seconds after which no schema build or first run starts; what did not run is reported, exit 0.")
    var budget: Int?
    @Option(help: "Run at most this many mutants, changed lines first; the rest are reported as not run.")
    var maxMutants: Int?
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
            "copy (default: a fresh copy), persistent:<dir> (kept and synchronised: incremental builds), or in-place (CI: the checkout itself, originals backed up and restored)."
    )
    var workspace: String = "copy"
    @Option(
        help:
            "Directory holding Xcode's DerivedData (reuse a CI job's build); default: the run's or the persistent one."
    )
    var buildDirectory: String?
    mutating func run() async throws {
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
        options.budgetSeconds = budget
        options.maxMutants = maxMutants
        options.inactiveSchemaBaseline = !unmutatedBaseline
        options.resultStore = resultStore
        options.storeReadOnly = storeReadOnly
        options.storeLimitMiB = storeLimit
        options.resume = resume
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
        do {
            driver = try BuildDriver(
                root: subject.absoluteRoot,
                container: project,
                scheme: scheme,
                destination: destination
            )
        } catch { try fail(error, code: .usage) }
        driver.swiftPMBuildSystem = swiftpmBuildSystem
        if !driver.usesXcode && !FileManager.default.fileExists(atPath: subject.absoluteRoot + "/Package.swift") {
            throw ValidationError(
                "host package requires Package.swift; Xcode projects need --project, --scheme and --destination"
            )
        }
        options.exclude = try subject.excludes()
        options.include = try subject.includes()
        do { options.scope = try await change.scope(root: subject.absoluteRoot) } catch let error as ValidationError {
            throw error
        } catch { try fail(error, code: .usage) }
        let artifact: RunArtifact
        let (runDriver, runOptions, runOutput) = (driver, options, output)
        do {
            // A signal cancels the run: its children are ended and its checkpoint written (analyzerkit ADR-0030).
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
        print(String(decoding: try ArtifactCodec.json(artifact), as: UTF8.self))
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
            stderr("litmus: \(budget.untested.count) mutant(s) not run: the \(stopped) limit was reached")
        }
        if let cost = artifact.cost {
            stderr(
                "litmus: cost: \(cost.builds) build(s), \(cost.testRuns) test run(s), CPU \(cost.childCPUSeconds) s "
                    + "(children) + \(cost.litmusCPUSeconds) s, peak memory \(cost.childPeakRSSMiB) MiB (largest child), "
                    + "disk \(cost.runDirectoryMiB) MiB"
            )
        }
        if !artifact.isSuccessfulExecution { throw ExitCode(ExitStatus.internalFailure.rawValue) }
    }
}

private struct Restore: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Restore the files an interrupted in-place run left rewritten (from <root>/.litmus/restore)."
    )
    @Argument(help: "Subject root of the in-place run.") var root: String = "."
    mutating func run() async throws {
        let root = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
        do {
            let restored = try InPlaceRestore.restore(root: root)
            stderr("litmus: \(restored) file(s) restored in \(root)")
        } catch { try fail(error, code: .internalFailure) }
    }
}

private struct Analyze: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Report historical mutation evidence; validate all input bytes before allowing a green gate."
    )
    @Argument(help: "Current subject root.") var root: String = "."
    @Option(help: "Run artifact (.json or .pb). Missing data never means clean.") var results: String
    @Option(help: "xcode, json or sarif.") var format: String = "xcode"
    @Option(help: "Print paths relative to this root (must be the current subject root in this version).")
    var relativeTo: String?
    @Option(help: "Scope the report to a source file (repeatable), not test execution.") var only: [String] = []
    @Option(help: "Read report scope from a newline-delimited path file.") var onlyFrom: String?
    @Flag(help: "Fail on survivors (warnings) as well as unresolved outcomes.") var strict = false
    mutating func run() async throws {
        guard ["xcode", "json", "sarif"].contains(format) else {
            throw ValidationError("format must be xcode, json or sarif")
        }
        let root = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
        if let relativeTo, URL(fileURLWithPath: relativeTo).standardizedFileURL.resolvingSymlinksInPath().path != root {
            throw ValidationError("--relative-to must name the subject root in this version")
        }
        var scope: Set<String>? = only.isEmpty && onlyFrom == nil ? nil : Set(only)
        if let onlyFrom {
            do {
                let paths = try ArtifactCodec.paths(from: onlyFrom)
                scope = (scope ?? []).union(paths)
            } catch { try fail(error, code: .usage) }
        }
        let report: MutationReport
        do {
            let artifact = try ArtifactCodec.read(RunArtifact.self, path: results)
            report = try await MutationReport.make(artifact, root: root, relative: relativeTo != nil, only: scope)
        } catch { try fail(error, code: .internalFailure) }
        do { print(try LitmusReportFormat.render(report, format: format, root: relativeTo == nil ? nil : root)) } catch
        { try fail(error, code: .outputFailure) }
        stderr(LitmusReportFormat.summary(report))
        if !report.successfulExecution { throw ExitCode(ExitStatus.internalFailure.rawValue) }
        if report.findings.contains(where: { $0.severity == "error" || strict && $0.severity == "warning" }) {
            throw ExitCode(ExitStatus.findings.rawValue)
        }
    }
}

private func stderr(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
private func fail(_ error: any Error, code: ExitStatus) throws -> Never {
    stderr("litmus: error: \(error)")
    throw ExitCode(code.rawValue)
}
