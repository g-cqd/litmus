import Foundation
import ArgumentParser
import AnalyzerCLI
import LitmusCore

@main struct Litmus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Evidence-led mutation testing for Swift packages and Xcode projects.", version: "0.1.0-dev",
        subcommands: [Plan.self, Run.self, Analyze.self])
}

private struct SubjectOptions: ParsableArguments {
    @Argument(help: "Subject root containing all local dependencies; never modified by Litmus.") var root: String = "."
    @Option(help: "Configuration file; only exclude is currently supported.") var config: String?
    @Option(name: .customLong("exclude-path"), help: "Exclude a substring/glob from mutation discovery (repeatable).") var exclusions: [String] = []
    var absoluteRoot: String { URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path }
    func excludes() throws -> [String] {
        do { return try LitmusConfiguration.load(root: absoluteRoot, explicit: config).exclude + exclusions }
        catch { try fail(error, code: .badConfiguration) }
    }
}

private struct Plan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Discover syntax mutation candidates without building or executing project code.")
    @OptionGroup var subject: SubjectOptions
    @Option(help: "Output plan (.json or .pb); stdout JSON when omitted.") var output: String?
    @Option(help: "Bounded source-discovery parallelism, 1...16.") var jobs: Int = 4
    mutating func run() async throws {
        guard (1...16).contains(jobs) else { throw ValidationError("jobs must be 1...16") }
        let excludes = try subject.excludes()
        let plan: MutationPlan
        do { plan = try await MutationPlanner.plan(root: subject.absoluteRoot, exclude: excludes, jobs: jobs) }
        catch { try fail(error, code: .usage) }
        do {
            if let output { try ArtifactCodec.write(plan, path: output) }
            else { print(String(decoding: try ArtifactCodec.json(plan), as: UTF8.self)) }
        } catch { try fail(error, code: .outputFailure) }
        stderr("litmus: \(plan.mutations.count) candidates, \(plan.suppressed.count) suppressed in \(plan.analyzedFiles) files; plan is not test evidence")
        if plan.notes.contains(where: \.isDegraded) { throw ExitCode(ExitStatus.internalFailure.rawValue) }
    }
}

private struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Build and test mutants in an owned snapshot. Executes trusted project code.")
    @OptionGroup var subject: SubjectOptions
    @Option(help: "Relative .xcodeproj/.xcworkspace inside root. Omit for Swift packages.") var project: String?
    @Option(help: "Xcode scheme (required for iOS packages/projects).") var scheme: String?
    @Option(help: "Xcode destination (supply an existing simulator ID for reproducibility).") var destination: String?
    @Option(help: "New run directory OUTSIDE the source tree; contains checkpoints, evidence and build artifacts.") var output: String
    @Option(help: "Maximum non-overlapping sites per schema, 1...256.") var batchSize: Int = 64
    @Option(help: "Build deadline in seconds, 1...86400.") var buildTimeout: Int = 900
    @Option(help: "Test deadline in seconds, 1...86400.") var timeout: Int = 120
    @Flag(help: "Required: authorize executing package manifests, plugins, build scripts and tests. Copying is NOT an OS sandbox.") var trustProject = false
    @Flag(help: "Retain the workspace after a completed run; failed runs are always retained.") var keepWorkspace = false
    mutating func run() async throws {
        guard trustProject else { throw ValidationError("execution requires --trust-project; untrusted PRs need an isolated disposable runner") }
        guard (1...256).contains(batchSize), (1...86400).contains(timeout), (1...86400).contains(buildTimeout) else {
            throw ValidationError("batch-size/timeouts outside documented bounds")
        }
        let driver: BuildDriver
        do { driver = try BuildDriver(root: subject.absoluteRoot, container: project, scheme: scheme, destination: destination) }
        catch { try fail(error, code: .usage) }
        if !driver.usesXcode && !FileManager.default.fileExists(atPath: subject.absoluteRoot + "/Package.swift") {
            throw ValidationError("host package requires Package.swift; Xcode projects need --project, --scheme and --destination")
        }
        let excludes = try subject.excludes()
        let artifact: RunArtifact
        do {
            artifact = try await MutationRunner(executor: BoundedExecutor()).run(driver: driver, outputDirectory: output, exclude: excludes,
                batchSize: batchSize, buildTimeout: buildTimeout, testTimeout: timeout, keepWorkspace: keepWorkspace)
        } catch { try fail(error, code: .internalFailure) }
        print(String(decoding: try ArtifactCodec.json(artifact), as: UTF8.self))
        stderr("litmus: \(artifact.results.count) outcomes; evidence at \(output)/run.json")
        if !artifact.isSuccessfulExecution { throw ExitCode(ExitStatus.internalFailure.rawValue) }
    }
}

private struct Analyze: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Report historical mutation evidence; validate all input bytes before allowing a green gate.")
    @Argument(help: "Current subject root.") var root: String = "."
    @Option(help: "Run artifact (.json or .pb). Missing data never means clean.") var results: String
    @Option(help: "xcode, json or sarif.") var format: String = "xcode"
    @Option(help: "Print paths relative to this root (must be the current subject root in this version).") var relativeTo: String?
    @Option(help: "Scope the report to a source file (repeatable), not test execution.") var only: [String] = []
    @Option(help: "Read report scope from a newline-delimited path file.") var onlyFrom: String?
    @Flag(help: "Fail on survivors (warnings) as well as unresolved outcomes.") var strict = false
    mutating func run() async throws {
        guard ["xcode", "json", "sarif"].contains(format) else { throw ValidationError("format must be xcode, json or sarif") }
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
            report = try MutationReport.make(artifact, root: root, relative: relativeTo != nil, only: scope)
        } catch { try fail(error, code: .internalFailure) }
        do { print(try LitmusReportFormat.render(report, format: format, root: relativeTo == nil ? nil : root)) }
        catch { try fail(error, code: .outputFailure) }
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
