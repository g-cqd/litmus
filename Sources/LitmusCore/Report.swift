internal import Foundation
internal import SourceCorpus
public import ProjectModel
public import ReportSupport

/// A finding uses the analyzer family's diagnostic and baseline identity contract.
public struct MutationFinding: Codable, Sendable, ReportedFinding {
    public let path: String
    public let line: Int
    public let column: Int
    public let rule: String
    public let severity: String
    public let message: String
    public let fingerprint: String
    public var severityName: String { severity }
    public var ruleName: String { rule }
    public var displayMessage: String { message }

    init(_ result: MutationResult, root: String?) {
        let site = result.mutation
        path = root.map { $0 + "/" + site.path } ?? site.path
        line = site.line; column = site.column
        rule = "litmus/" + result.verdict.rawValue
        severity = result.verdict == .survived ? "warning" : "error"
        message = "\(site.operatorID.rawValue): \(site.original) → \(site.replacement); \(result.reason)"
        fingerprint = Fingerprint.make(rule: rule, path: site.path, line: line, column: column, message: message)
    }
}

/// A file that the report could not verify.
public struct ReportDegradation: Codable, Sendable, ReportedDegradedFile {
    public let path: String
    public let reason: String
    public var displayText: String { reason }
}

/// An execution report deliberately has no single mutation score when any outcome is unresolved.
public struct MutationReport: Codable, Sendable, ToolReport {
    public let findings: [MutationFinding]
    public let outOfScope: [MutationFinding]
    public let suppressed: [MutationFinding]
    public let degradedFiles: [ReportDegradation]
    public let analyzedFileCount: Int
    public let wasCancelled: Bool
    public let counts: [String: Int]
    public let executionComplete: Bool
    public let successfulExecution: Bool
    public let evidenceStartedAt: String
    public let snapshotSHA256: String
    public let verification: String
    public let notes: [String]
    public var suppressedCount: Int { suppressed.count }
    public var classificationIssues: [ClassificationIssue] { [] }
    public var timings: [String: Double] { [:] }
    public var leadingRunNotes: [RunNote] {
        notes.map { RunNote(code: "litmus/execution-evidence", severity: "note", message: $0) }
    }

    /// Validates the record and all current input bytes, including tests/resources/settings and newly added files.
    /// This establishes correspondence to source, not authenticity or current toolchain equivalence.
    public static func make(_ artifact: RunArtifact, root: String, relative: Bool = false, only: Set<String>? = nil, baseline: Set<String> = []) throws -> Self {
        guard artifact.version == 1, artifact.plan.version == 1,
            artifact.provenance.toolVersion == "0.1.0-dev",
            artifact.provenance.executionPolicy == "full-suite/process-per-mutant/confirmed-failure/v1",
            !artifact.provenance.inputs.isEmpty,
            Digest.sha256(try ArtifactCodec.json(artifact.provenance.inputs)) == artifact.provenance.snapshotSHA256,
            Set(artifact.plan.mutations.map(\.id)).count == artifact.plan.mutations.count,
            Set(artifact.results.map { $0.mutation.id }).count == artifact.results.count,
            artifact.results.count == artifact.plan.mutations.count
        else { throw LitmusFailure("unsupported or inconsistent run artifact") }
        let expected = Dictionary(uniqueKeysWithValues: artifact.plan.mutations.map { ($0.id, $0) })
        guard artifact.results.allSatisfy({ expected[$0.mutation.id] == $0.mutation }) else {
            throw LitmusFailure("result/plan reconciliation failed")
        }
        let stale = try changedInputs(artifact.provenance.inputs, root: root)
        let degradations = stale.map { ReportDegradation(path: $0, reason: "input differs from execution snapshot; verdicts are historical only") } +
            artifact.plan.notes.filter(\.isDegraded).map { ReportDegradation(path: $0.path, reason: $0.reason) }
        let all = artifact.results.filter { ![Verdict.killed].contains($0.verdict) }.map { MutationFinding($0, root: relative ? nil : root) }
        let suppressed = all.filter { baseline.contains($0.fingerprint) }
        let unsuppressed = all.filter { !baseline.contains($0.fingerprint) }
        let scoped = unsuppressed.filter { finding in only.map { $0.contains(finding.path.hasPrefix(root + "/") ? String(finding.path.dropFirst(root.count + 1)) : finding.path) } ?? true }
        let out = unsuppressed.filter { finding in !scoped.contains(where: { $0.fingerprint == finding.fingerprint }) }
        return Self(findings: scoped, outOfScope: out, suppressed: suppressed, degradedFiles: degradations,
            analyzedFileCount: artifact.plan.analyzedFiles, wasCancelled: !artifact.complete,
            counts: Dictionary(grouping: artifact.results, by: { $0.verdict.rawValue }).mapValues(\.count),
            executionComplete: artifact.complete, successfulExecution: artifact.isSuccessfulExecution && stale.isEmpty,
            evidenceStartedAt: artifact.provenance.startedAt, snapshotSHA256: artifact.provenance.snapshotSHA256,
            verification: "source snapshot checked; historical execution, not a new test run or certification",
            notes: artifact.notes + ["No static reference heuristic is treated as test coverage. No equivalent-mutant pruning or verdict-cache reuse is performed."])
    }

    private static func changedInputs(_ entries: [SnapshotEntry], root: String) throws -> [String] {
        let root = SourcePath.canonical(root)
        guard Set(entries.map(\.path)).count == entries.count else { throw LitmusFailure("duplicate snapshot input paths") }
        let expected = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0.sha256) })
        var actual: Set<String> = [], changed: [String] = [], enumerationFailed = false
        guard let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], errorHandler: { _, _ in enumerationFailed = true; return false }) else {
            throw LitmusFailure("cannot verify source inventory")
        }
        var count = 0
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            if WorkspaceSnapshot.skipped.contains(url.lastPathComponent) { enumerator.skipDescendants(); continue }
            count += 1
            guard count <= 150_000 else { throw LitmusFailure("source inventory exceeds entry limit") }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            let canonical = SourcePath.canonical(url.path)
            guard canonical.hasPrefix(root + "/") else { throw LitmusFailure("source inventory entry escapes root") }
            let relative = String(canonical.dropFirst(root.count + 1))
            if values.isSymbolicLink == true { throw LitmusFailure("source inventory has symbolic link: \(relative)") }
            if values.isRegularFile == true {
                actual.insert(relative)
                let hash = Digest.sha256(try BoundedFileReader.read(path: url.path, cap: 128 << 20))
                if expected[relative] != hash { changed.append(relative) }
            }
        }
        guard !enumerationFailed else { throw LitmusFailure("source inventory could not be verified") }
        changed += Set(expected.keys).subtracting(actual)
        return changed.sorted()
    }
}

/// Uses analyzerkit for Xcode diagnostics, envelope/SARIF fields, columns and diagnostic wording.
public enum LitmusReportFormat: ToolReportFormat {
    public typealias Report = MutationReport
    public static let toolName = "litmus"
    public static let toolVersion = "0.1.0-dev"
    public static let informationURI = "https://github.com/g-cqd/litmus"
    public static let byteOrderMark = SarifColumns.ByteOrderMark.parsed
    public static let readCap = 2 << 20
    public static var sarifRules: [Sarif.Rule] {
        [Verdict.survived, .timeout, .invalid, .infrastructureError, .notRun].map {
            Sarif.Rule(id: "litmus/" + $0.rawValue, shortDescription: Sarif.Text($0.rawValue))
        }
    }
}


extension LitmusReportFormat {
    /// Throwing serialization never substitutes an empty JSON object for an encoding failure.
    public static func render(_ report: MutationReport, format: String, root: String?) throws -> String {
        switch format {
        case "xcode": return Self.format(report, as: .xcode, relativeTo: root)
        case "json":
            return String(decoding: try ArtifactCodec.json(ReportEnvelope(report, tool: toolName, version: toolVersion,
                runNotes: report.leadingRunNotes,
                skippedFiles: report.degradedFiles.map { SkippedFile(path: $0.path, reason: .changedSinceBuild) })), as: UTF8.self)
        case "sarif":
            var columns = SarifColumns(root: root, byteOrderMark: .parsed, readCap: readCap)
            let results = report.findings.map { finding in
                Sarif.Result(ruleId: finding.rule, level: finding.severity, message: Sarif.Text(finding.message), locations: [
                    Sarif.Location(physicalLocation: Sarif.PhysicalLocation(artifactLocation: Sarif.ArtifactLocation(path: finding.path, root: root),
                        region: Sarif.Region(startLine: finding.line, startColumn: columns.column(finding.column, line: finding.line, path: finding.path))))
                ], partialFingerprints: ["litmus/v1": finding.fingerprint])
            }
            let log = Sarif.Log(runs: [Sarif.Run(tool: Sarif.Tool(driver: Sarif.Driver(name: toolName, version: toolVersion,
                informationUri: informationURI, rules: sarifRules)),
                invocations: [Sarif.Invocation(failure: report.successfulExecution ? nil : "incomplete, stale or unresolved mutation execution", warnings: report.notes)],
                root: root, results: results)])
            return String(decoding: try ArtifactCodec.json(log), as: UTF8.self)
        default: throw LitmusFailure("unknown report format: \(format)")
        }
    }
}
