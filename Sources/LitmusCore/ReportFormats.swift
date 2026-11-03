internal import AemiIO
internal import Foundation
internal import SourceCorpus

/// A pull request's job summary (`analyze --format markdown`): the score, what ran and what it cost, and the
/// findings in a table. GitHub renders it in `$GITHUB_STEP_SUMMARY`; Danger can post it.
public enum MarkdownReport {
    public static func render(_ report: MutationReport, artifact: RunArtifact) -> String {
        var lines: [String] = ["## Litmus mutation testing", ""]
        let counts = Verdict.allCases.compactMap { verdict in
            report.counts[verdict.rawValue].map { "\(verdict.rawValue) \($0)" }
        }
        let score = artifact.score
        if let percent = score.percent {
            let covered = score.coveredPercent.map { "; \(format($0)) % of covered mutants" } ?? ""
            lines.append(
                "**Score \(format(percent)) %** (\(score.detected) detected of \(score.detected + score.undetected)"
                    + "\(covered))"
            )
        } else if artifact.results.isEmpty {
            lines.append("**No mutant in scope.**")
        } else {
            lines.append("**No score:** \(score.unresolved) mutant(s) without a resolved verdict.")
        }
        lines.append("")
        var facts: [String] = []
        facts.append(
            "\(artifact.results.count) mutant(s)" + (counts.isEmpty ? "" : ": " + counts.joined(separator: ", "))
        )
        if let scope = artifact.plan.scope {
            facts.append(
                "Scope: \(escape(scope.source)): \(scope.swiftFiles) changed Swift file(s), "
                    + "\(scope.onChangedLines.count) mutant(s) on changed lines (\(scope.breadth.rawValue))"
            )
        }
        if let reuse = artifact.reuse, reuse.resumed + reuse.fromStore > 0 {
            facts.append("Reused: \(reuse.resumed + reuse.fromStore) verdict(s), \(reuse.mode.rawValue) keys")
        }
        if let budget = artifact.budget, let stopped = budget.stoppedBy {
            facts.append("Budget: \(budget.untested.count) mutant(s) not run (\(stopped) limit)")
        }
        if let cost = artifact.cost {
            facts.append(
                "Cost: \(format(cost.wallSeconds)) s, \(cost.builds) build(s), \(cost.testRuns) test run(s), "
                    + "CPU \(format(cost.childCPUSeconds)) s, peak \(format(cost.childPeakRSSMiB)) MiB"
            )
        }
        if !report.successfulExecution { facts.append("**Execution incomplete, stale or unresolved: see the notes.**") }
        lines += facts.map { "- " + $0 }
        let shown = report.findings.filter { $0.severity != "note" || $0.rule == "litmus/unviable" }
        if !shown.isEmpty {
            lines += ["", "| | Location | Mutation | Verdict | Why |", "| --- | --- | --- | --- | --- |"]
            let byID = Dictionary(artifact.results.map { ($0.mutation.id, $0) }, uniquingKeysWith: { a, _ in a })
            let order = ["error": 0, "warning": 1, "note": 2]
            for finding in shown.sorted(by: {
                (order[$0.severity] ?? 3, $0.path, $0.line) < (order[$1.severity] ?? 3, $1.path, $1.line)
            }).prefix(200) {
                guard let result = byID[finding.mutationID] else { continue }
                let mark = finding.severity == "error" ? "❌" : finding.severity == "warning" ? "⚠️" : "ℹ️"
                let site = result.mutation
                lines.append(
                    "| \(mark) | `\(escape(site.path)):\(site.line)` | `\(escape(code(site.original)))` → "
                        + "`\(escape(code(site.replacement)))` | \(result.verdict.rawValue) | \(escape(result.reason)) |"
                )
            }
            if shown.count > 200 { lines += ["", "… and \(shown.count - 200) more in the full report."] }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String((value * 100).rounded() / 100)
    }

    /// Table-safe: no pipe or line break ends a cell.
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }

    /// Code on one line, at most 120 characters, without backticks that would end the span.
    private static func code(_ text: String) -> String {
        let flat = normalized(text).replacingOccurrences(of: "`", with: "'")
        return flat.count > 120 ? String(flat.prefix(117)) + "..." : flat
    }
}

/// Stryker's mutation-testing-report-schema, version 2 (`analyze --format stryker`): what Stryker's dashboard and
/// HTML report element read, so Litmus runs can be viewed and compared with other tools' (design 0001 §6).
///
/// Verdicts map to Stryker's statuses: killed `Killed`, crashed `RuntimeError`, timeout `Timeout`, survived `Survived`,
/// no coverage `NoCoverage`, unviable `CompileError`, not run `Pending`, and an infrastructure error `Ignored` with its
/// reason (Stryker has no status for "no verdict"; Litmus itself gives no score while one exists).
public enum StrykerReport {
    struct Report: Encodable {
        let schemaVersion = "2"
        let thresholds = Thresholds()
        let projectRoot: String
        let files: [String: File]
        let framework = Framework()
        struct Thresholds: Encodable {
            let high = 80
            let low = 60
        }
        struct Framework: Encodable {
            let name = "litmus"
            let version = LitmusVersion.current
        }
    }

    struct File: Encodable {
        let language = "swift"
        let source: String
        let mutants: [Mutant]
    }

    struct Mutant: Encodable {
        let id: String
        let mutatorName: String
        let replacement: String
        let location: Location
        let status: String
        let statusReason: String
        let duration: Int
        let killedBy: [String]?
    }

    struct Location: Encodable {
        let start: Position
        let end: Position
    }

    struct Position: Encodable {
        let line: Int
        let column: Int
    }

    /// The report of `artifact`, with each file's source read from `root` (bounded; the report's checks have already
    /// established that the inputs are the ones the run tested).
    public static func render(_ artifact: RunArtifact, root: String) throws -> String {
        var files: [String: File] = [:]
        for (path, results) in Dictionary(grouping: artifact.results, by: \.mutation.path) {
            let bytes = try BoundedFileReader.read(path: root + "/" + path, cap: 2 << 20)
            let source = String(decoding: bytes, as: UTF8.self)
            let mutants = results.sorted { $0.mutation.start < $1.mutation.start }.map { result in
                let site = result.mutation
                let lines = site.original.split(separator: "\n", omittingEmptySubsequences: false)
                // Stryker's end is exclusive, in characters.
                let endColumn = (lines.count == 1 ? site.column : 1) + (lines.last.map { $0.count } ?? 0)
                let killers =
                    result.reason.hasPrefix("killed by ")
                    ? String(result.reason.dropFirst("killed by ".count)).components(separatedBy: ", ").map {
                        $0.components(separatedBy: " ").first ?? $0
                    } : nil
                return Mutant(
                    id: site.id,
                    mutatorName: site.operatorID.rawValue,
                    replacement: site.replacement,
                    location: Location(
                        start: Position(line: site.line, column: site.column),
                        end: Position(line: site.endLine, column: endColumn)
                    ),
                    status: status(result.verdict),
                    statusReason: result.reusedFrom.map { "\(result.reason) (reused from \($0))" } ?? result.reason,
                    duration: Int(result.nanoseconds / 1_000_000),
                    killedBy: result.verdict == .killed ? killers : nil
                )
            }
            files[path] = File(source: source, mutants: mutants)
        }
        return String(
            decoding: try ArtifactCodec.json(Report(projectRoot: root, files: files)),
            as: UTF8.self
        )
    }

    static func status(_ verdict: Verdict) -> String {
        switch verdict {
        case .killed: "Killed"
        case .crashed: "RuntimeError"
        case .timeout: "Timeout"
        case .survived: "Survived"
        case .noCoverage: "NoCoverage"
        case .unviable: "CompileError"
        case .notRun: "Pending"
        case .infrastructureError: "Ignored"
        }
    }
}
