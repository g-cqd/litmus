internal import Foundation
internal import SourceCorpus

/// One self-contained HTML file (`analyze --format html`): a tree of directories and files with logic and UI scores, the
/// source with each line colored by its mutants' verdicts, and per line a drawer with each mutant's diff, reason,
/// reaching tests and the commands to rerun or accept it. No request leaves the page: its Content-Security-Policy
/// allows only its own inline style and script.
public enum HTMLReport {
    struct Page: Encodable {
        let title: String
        let run: String
        let score: String
        let logic: String?
        let ui: String?
        let files: [File]
    }

    struct File: Encodable {
        let path: String
        let source: String?
        let mutants: [Entry]
    }

    struct Entry: Encodable {
        let id: String
        let line: Int
        let endLine: Int
        let column: Int
        let operatorID: String
        let domain: String
        let original: String
        let replacement: String
        let verdict: String
        let reason: String
        let milliseconds: Int64
        let reach: [String]
        let accepted: String?
    }

    /// The page for `artifact`; sources are read from `root` (a file that cannot be read shows its mutants only).
    /// `run` is the run directory or artifact path the page's `litmus accept` commands name.
    public static func render(_ artifact: RunArtifact, root: String, run: String) throws -> String {
        let accepted = artifact.plan.acceptance?.accepted ?? [:]
        let byFile = Dictionary(grouping: artifact.results, by: \.mutation.path)
        let files = byFile.keys.sorted().map { path in
            let source = (try? BoundedFileReader.read(path: root + "/" + path, cap: 4 << 20))
                .map { String(decoding: $0, as: UTF8.self) }
            let entries = (byFile[path] ?? []).sorted {
                ($0.mutation.line, $0.mutation.column) < ($1.mutation.line, $1.mutation.column)
            }
            .map { result in
                Entry(
                    id: result.mutation.id,
                    line: result.mutation.line,
                    endLine: result.mutation.endLine,
                    column: result.mutation.column,
                    operatorID: result.mutation.operatorID.rawValue,
                    domain: result.mutation.operatorID.domain == .ui ? "ui" : "logic",
                    original: result.mutation.original,
                    replacement: result.mutation.replacement,
                    verdict: result.verdict.rawValue,
                    reason: result.reason,
                    milliseconds: result.nanoseconds / 1_000_000,
                    reach: artifact.perTestReach?[result.mutation.id] ?? [],
                    accepted: accepted[result.mutation.id]
                )
            }
            return File(path: path, source: source, mutants: entries)
        }
        let page = Page(
            title: "Litmus: " + (URL(fileURLWithPath: root).lastPathComponent),
            run: run,
            score: GitHubSummaryReport.percent(artifact.score, nil),
            logic: artifact.logicScore.map { GitHubSummaryReport.percent($0, nil) },
            ui: artifact.uiScore.map { GitHubSummaryReport.percent($0, nil) },
            files: files
        )
        let json = String(decoding: try ArtifactCodec.json(page), as: UTF8.self)
        return HTMLReportPage.document(title: page.title, data: embeddable(json))
    }

    /// JSON that cannot end its `<script>` element or open markup: `<`, `>` and `&` only ever occur inside JSON
    /// strings, where their `\u` escapes mean the same.
    static func embeddable(_ json: String) -> String {
        json.replacingOccurrences(of: "&", with: "\\u0026").replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
    }
}
