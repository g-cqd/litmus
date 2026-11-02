internal import Foundation
public import ProjectModel
public import ReportSupport
internal import SourceCorpus

/// A finding uses the analyzer family's diagnostic and baseline identity contract.
public struct MutationFinding: Codable, Sendable, ReportedFinding {
    public let path: String
    public let line: Int
    public let column: Int
    public let rule: String
    public let severity: String
    public let message: String
    public let fingerprint: String
    /// The mutant's id, to find it in the run.
    public let mutationID: String
    public var severityName: String { severity }
    public var ruleName: String { rule }
    public var displayMessage: String { message }
    /// Survives edits elsewhere in the file: the verdict's rule and the mutant's anchored id (ADR 0007). Written to
    /// SARIF as `litmus/anchored/v1`; what `--gate new-survivors` compares.
    public let anchoredFingerprint: String?

    /// - Parameter untested: a budget left it untested: a note, not an unresolved outcome.
    init(_ result: MutationResult, root: String?, untested: Bool = false) {
        let site = result.mutation
        mutationID = site.id
        path = root.map { $0 + "/" + site.path } ?? site.path
        line = site.line; column = site.column
        rule = "litmus/" + result.verdict.rawValue
        severity =
            switch result.verdict {
            case .survived, .noCoverage: "warning"
            case .unviable: "note"
            case .notRun where untested: "note"
            default: "error"
            }
        message = "\(site.operatorID.rawValue): \(site.original) → \(site.replacement); \(result.reason)"
        fingerprint = Fingerprint.make(rule: rule, path: site.path, line: line, column: column, message: message)
        anchoredFingerprint = "a" + Fingerprint.string(of: Fingerprint.hash("\(rule)|\(site.path)|\(site.id)"))
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
    /// The Stryker-defined score; nil while any verdict is unresolved.
    public let score: MutationScore
    public let policy: RunPolicy?
    public let executionTimings: [String: Double]
    public var suppressedCount: Int { suppressed.count }
    public var classificationIssues: [ClassificationIssue] { [] }
    public var timings: [String: Double] { [:] }
    public var leadingRunNotes: [RunNote] {
        notes.map { RunNote(code: "litmus/execution-evidence", severity: "note", message: $0) }
    }

    /// Validates the record and all current input bytes, including tests/resources/settings and newly added files.
    /// This establishes correspondence to source, not authenticity or current toolchain equivalence.
    public static func make(
        _ artifact: RunArtifact,
        root: String,
        relative: Bool = false,
        only: Set<String>? = nil,
        baseline: Set<String> = [],
        change: ChangeScope? = nil
    ) async throws -> Self {
        guard artifact.version == 2, artifact.plan.version == 1,
            artifact.provenance.toolVersion == LitmusVersion.current,
            artifact.provenance.executionPolicy == RunArtifact.executionPolicy,
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
        let stale = try await changedInputs(artifact.provenance.inputs, root: root)
        let degradations =
            stale.map {
                ReportDegradation(
                    path: $0,
                    reason: "input differs from execution snapshot; verdicts are historical only"
                )
            } + artifact.plan.notes.filter(\.isDegraded).map { ReportDegradation(path: $0.path, reason: $0.reason) }
        let all = artifact.results.filter { !$0.verdict.isDetected }.map {
            MutationFinding($0, root: relative ? nil : root, untested: artifact.budgetLeftUntested($0))
        }
        // A baseline holds anchored fingerprints (lines may move) or the classic ones.
        func baselined(_ finding: MutationFinding) -> Bool {
            baseline.contains(finding.fingerprint) || finding.anchoredFingerprint.map(baseline.contains) == true
        }
        let suppressed = all.filter(baselined)
        let unsuppressed = all.filter { !baselined($0) }
        let byID = Dictionary(artifact.results.map { ($0.mutation.id, $0.mutation) }, uniquingKeysWith: { a, _ in a })
        let scoped = unsuppressed.filter { finding in
            let relative =
                finding.path.hasPrefix(root + "/") ? String(finding.path.dropFirst(root.count + 1)) : finding.path
            let inFiles = only.map { $0.contains(relative) } ?? true
            let inChange = change.map { scope in byID[finding.mutationID].map { scope.priority(of: $0) != nil } ?? false
            }
            return inFiles && (inChange ?? true)
        }
        let out = unsuppressed.filter { finding in !scoped.contains(where: { $0.fingerprint == finding.fingerprint }) }
        return Self(
            findings: scoped,
            outOfScope: out,
            suppressed: suppressed,
            degradedFiles: degradations,
            analyzedFileCount: artifact.plan.analyzedFiles,
            wasCancelled: !artifact.complete,
            counts: Dictionary(grouping: artifact.results, by: { $0.verdict.rawValue }).mapValues(\.count),
            executionComplete: artifact.complete,
            successfulExecution: artifact.isSuccessfulExecution && stale.isEmpty,
            evidenceStartedAt: artifact.provenance.startedAt,
            snapshotSHA256: artifact.provenance.snapshotSHA256,
            verification: "source snapshot checked; historical execution, not a new test run or certification",
            notes: artifact.notes + [
                "Coverage is the activation markers observed while the tests ran, never a static guess. "
                    + "No equivalent-mutant pruning is performed; a reused verdict names the run that decided it."
            ],
            score: artifact.score,
            policy: artifact.policy,
            executionTimings: artifact.timings
        )
    }

    /// Inputs whose bytes differ from the snapshot, plus inputs added or removed, by aemi's `DirectoryWalk` and
    /// parallel SHA-256.
    private static func changedInputs(_ entries: [SnapshotEntry], root: String) async throws -> [String] {
        let root = SourcePath.canonical(root)
        guard Set(entries.map(\.path)).count == entries.count else {
            throw LitmusFailure("duplicate snapshot input paths")
        }
        let expected = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0.sha256) })
        let current = try await WorkspaceSnapshot.currentEntries(root)
        var changed = current.filter { expected[$0.path] != $0.sha256 }.map(\.path)
        changed += Set(expected.keys).subtracting(current.map(\.path))
        return changed.sorted()
    }
}

/// Uses analyzerkit for Xcode diagnostics, envelope/SARIF fields, columns and diagnostic wording.
public enum LitmusReportFormat: ToolReportFormat {
    public typealias Report = MutationReport
    public static let toolName = "litmus"
    public static let toolVersion = LitmusVersion.current
    public static let informationURI = "https://github.com/g-cqd/litmus"
    public static let byteOrderMark = SarifColumns.ByteOrderMark.parsed
    public static let readCap = 2 << 20
    public static var sarifRules: [Sarif.Rule] {
        [Verdict.survived, .noCoverage, .unviable, .infrastructureError, .notRun].map {
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
            return String(
                decoding: try ArtifactCodec.json(
                    ReportEnvelope(
                        report,
                        tool: toolName,
                        version: toolVersion,
                        runNotes: report.leadingRunNotes,
                        skippedFiles: report.degradedFiles.map {
                            SkippedFile(path: $0.path, reason: .changedSinceBuild)
                        }
                    )
                ),
                as: UTF8.self
            )
        case "sarif":
            var columns = SarifColumns(root: root, byteOrderMark: .parsed, readCap: readCap)
            let results = report.findings.map { finding in
                Sarif.Result(
                    ruleId: finding.rule,
                    level: finding.severity,
                    message: Sarif.Text(finding.message),
                    locations: [
                        Sarif.Location(
                            physicalLocation: Sarif.PhysicalLocation(
                                artifactLocation: Sarif.ArtifactLocation(path: finding.path, root: root),
                                region: Sarif.Region(
                                    startLine: finding.line,
                                    startColumn: columns.column(finding.column, line: finding.line, path: finding.path)
                                )
                            )
                        )
                    ],
                    partialFingerprints: ["litmus/v1": finding.fingerprint].merging(
                        finding.anchoredFingerprint.map { ["litmus/anchored/v1": $0] } ?? [:]
                    ) { first, _ in first }
                )
            }
            let log = Sarif.Log(runs: [
                Sarif.Run(
                    tool: Sarif.Tool(
                        driver: Sarif.Driver(
                            name: toolName,
                            version: toolVersion,
                            informationUri: informationURI,
                            rules: sarifRules
                        )
                    ),
                    invocations: [
                        Sarif.Invocation(
                            failure: report.successfulExecution
                                ? nil : "incomplete, stale or unresolved mutation execution",
                            warnings: report.notes
                        )
                    ],
                    root: root,
                    results: results
                )
            ])
            return String(decoding: try ArtifactCodec.json(log), as: UTF8.self)
        default: throw LitmusFailure("unknown report format: \(format)")
        }
    }
}
