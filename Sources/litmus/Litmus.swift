import AnalyzerCLI
import ArgumentParser
import Foundation
import LitmusCore

@main struct Litmus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Evidence-led mutation testing for Swift packages and Xcode projects.",
        version: LitmusVersion.current,
        subcommands: [Plan.self, Run.self, Analyze.self, Census.self]
    )
}

private struct SubjectOptions: ParsableArguments {
    @Argument(help: "Subject root containing all local dependencies; never modified by Litmus.") var root: String = "."
    @Option(help: "Configuration file; only exclude is currently supported.") var config: String?
    @Option(name: .customLong("exclude-path"), help: "Exclude a substring/glob from mutation discovery (repeatable).")
    var exclusions: [String] = []
    var absoluteRoot: String { URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path }
    func excludes() throws -> [String] {
        do { return try LitmusConfiguration.load(root: absoluteRoot, explicit: config).exclude + exclusions } catch {
            try fail(error, code: .badConfiguration)
        }
    }
}

private struct Plan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Discover syntax mutation candidates without building or executing project code."
    )
    @OptionGroup var subject: SubjectOptions
    @Option(help: "Output plan (.json or .pb); stdout JSON when omitted.") var output: String?
    @Option(help: "Bounded source-discovery parallelism, 1...16.") var jobs: Int = 4
    mutating func run() async throws {
        guard (1...16).contains(jobs) else { throw ValidationError("jobs must be 1...16") }
        let excludes = try subject.excludes()
        let plan: MutationPlan
        do { plan = try await MutationPlanner.plan(root: subject.absoluteRoot, exclude: excludes, jobs: jobs) } catch {
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
    @Flag(help: "Build and run first passes at background priority; reruns that decide timeouts do not.")
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
        let counts = Dictionary(grouping: artifact.results, by: \.verdict).mapValues(\.count)
        let summary = Verdict.allCases.compactMap { verdict in counts[verdict].map { "\(verdict.rawValue) \($0)" } }
        let score = artifact.score.percent.map { String($0) + "%" } ?? "n/a"
        stderr(
            "litmus: \(artifact.results.count) mutants: \(summary.joined(separator: ", ")); score \(score); "
                + "\(((artifact.timings["total"] ?? 0) * 10).rounded() / 10) s; evidence at \(output)/run.json"
        )
        if !artifact.isSuccessfulExecution { throw ExitCode(ExitStatus.internalFailure.rawValue) }
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
