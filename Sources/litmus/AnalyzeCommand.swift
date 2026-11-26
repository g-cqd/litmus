import AnalyzerCLI
import ArgumentParser
import Foundation
import LitmusCore
import ReportSupport

struct Analyze: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Report historical mutation evidence; validate all input bytes before allowing a green gate."
    )
    @Argument(help: "Current subject root.") var root: String = "."
    @OptionGroup var change: ChangeOptions
    @Option(help: "Run artifact (.json or .pb). Missing data never means clean.") var results: String
    @Option(
        help:
            "xcode, json, sarif, markdown (job summary), stryker (mutation-testing-report-schema 2) or agent (one self-contained record per gap, for coding agents)."
    )
    var format: String = "xcode"
    @Option(help: "With --format agent: the gaps of logic, ui or all mutants.") var domain: String = "all"
    @Option(help: "Print paths relative to this root (must be the current subject root in this version).")
    var relativeTo: String?
    @Option(help: "Scope the report to a source file (repeatable), not test execution.") var only: [String] = []
    @Option(help: "Read report scope from a newline-delimited path file.") var onlyFrom: String?
    @Flag(help: "Fail on survivors (warnings) as well as unresolved outcomes.") var strict = false
    @Option(help: "Baseline file: findings whose fingerprints it holds are left out (anchored or classic).")
    var baseline: String?
    @Option(help: "Write the current findings' anchored fingerprints as a baseline to this file, then exit 0.")
    var writeBaseline: String?
    @OptionGroup var limits: GateOptions
    @Option(help: "new-survivors: fail on survivors and uncovered mutants the --baseline (base branch) does not hold.")
    var gate: String?
    mutating func run() async throws {
        guard ["xcode", "json", "sarif", "markdown", "stryker", "agent"].contains(format) else {
            throw ValidationError("format must be xcode, json, sarif, markdown, stryker or agent")
        }
        guard let agentDomain = AgentReport.Domain(rawValue: domain) else {
            throw ValidationError("domain must be logic, ui or all")
        }
        guard gate == nil || gate == "new-survivors" else { throw ValidationError("gate must be new-survivors") }
        if gate != nil, baseline == nil {
            throw ValidationError("--gate new-survivors needs --baseline: the base branch's baseline")
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
        var accepted: Set<String> = []
        if let baseline {
            do {
                let file = try ArtifactCodec.decode(
                    BaselineFile.self,
                    bytes: Array(try Data(contentsOf: URL(fileURLWithPath: baseline)))
                ).validated(requiringVersion: true)
                guard file.tool == "litmus" else { throw ValidationError("\(baseline) is a \(file.tool) baseline") }
                accepted = Set(file.fingerprints)
            } catch { try fail(error, code: .badConfiguration) }
        }
        let report: MutationReport
        let artifact: RunArtifact
        do {
            artifact = try ArtifactCodec.read(RunArtifact.self, path: results)
            report = try await MutationReport.make(
                artifact,
                root: root,
                relative: relativeTo != nil,
                only: scope,
                baseline: accepted,
                change: try await change.scope(root: root)
            )
        } catch { try fail(error, code: .internalFailure) }
        if let writeBaseline {
            let file = BaselineFile(
                tool: "litmus",
                fingerprints: report.findings.map { $0.anchoredFingerprint ?? $0.fingerprint },
                versioned: true
            )
            do { try ArtifactCodec.write(file, path: writeBaseline) } catch { try fail(error, code: .outputFailure) }
            stderr("litmus: baseline of \(file.fingerprints.count) finding(s) written to \(writeBaseline)")
            return
        }
        do {
            switch format {
            case "markdown": print(MarkdownReport.render(report, artifact: artifact), terminator: "")
            case "stryker": print(try StrykerReport.render(artifact, root: root))
            case "agent":
                let document = AgentReport.make(artifact, root: root, domain: agentDomain)
                print(String(decoding: try ArtifactCodec.json(document), as: UTF8.self))
            default: print(try LitmusReportFormat.render(report, format: format, root: relativeTo == nil ? nil : root))
            }
        } catch { try fail(error, code: .outputFailure) }
        stderr(LitmusReportFormat.summary(report))
        if !report.successfulExecution { throw ExitCode(ExitStatus.internalFailure.rawValue) }
        if try limits.fails(artifact) { throw ExitCode(ExitStatus.findings.rawValue) }
        let failOnWarnings = strict || gate != nil
        if report.findings.contains(where: { $0.severity == "error" || failOnWarnings && $0.severity == "warning" }) {
            throw ExitCode(ExitStatus.findings.rawValue)
        }
    }
}
