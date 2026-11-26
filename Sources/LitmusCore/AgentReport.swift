internal import Foundation
internal import ProjectModel
internal import SourceCorpus

/// `litmus analyze --format agent`: every gap of a run (survivors and uncovered mutants) as one self-contained record,
/// with the code around it, the tests that reached it, the test targets that cover its file, and the command that
/// re-verifies it, so a coding agent can close or accept each gap in one read.
public enum AgentReport {
    /// Which mutants the report lists.
    public enum Domain: String, CaseIterable, Sendable {
        case logic, ui, all
    }

    public struct Summary: Codable, Sendable, Equatable {
        public let scorePercent: Double?
        public let logicScorePercent: Double?
        public let uiScorePercent: Double?
        public let killed: Int
        public let crashed: Int
        public let timeout: Int
        public let survived: Int
        public let noCoverage: Int
        public let unviable: Int
        /// Accepted entries that match no mutant (`stale-missing`) or that a test now detects (`stale-killed`).
        public let staleAccepted: [String]
    }

    public struct Gap: Codable, Sendable, Equatable {
        public let id: String
        public let status: String
        /// `not_reached`: no test ran the code, write one that calls `declaration`. `reached_not_detected`: tests ran
        /// it and passed, strengthen their assertions or add the missing case, or accept a proven equivalence.
        public let diagnostic: String
        public let domain: String
        public let `operator`: String
        public let path: String
        public let line: Int
        public let column: Int
        public let declaration: String
        public let original: String
        public let replacement: String
        public let contextSnippet: String
        public let reachingTests: [String]
        public let coveringModules: [String]
        public let verifyCommand: String
    }

    public struct Document: Codable, Sendable, Equatable {
        public let summary: Summary
        public let gaps: [Gap]
    }

    /// The report of `artifact` over the subject at `root`, gaps in path, line, column and id order.
    public static func make(_ artifact: RunArtifact, root: String, domain: Domain = .all) -> Document {
        let root = SourcePath.canonical(root)
        let verdicts = artifact.results.map(\.verdict)
        let acceptance = artifact.plan.acceptance
        let summary = Summary(
            scorePercent: artifact.score.percent,
            logicScorePercent: artifact.logicScore?.percent ?? artifact.score.percent,
            uiScorePercent: artifact.uiScore?.percent,
            killed: verdicts.count { $0 == .killed },
            crashed: verdicts.count { $0 == .crashed },
            timeout: verdicts.count { $0 == .timeout },
            survived: verdicts.count { $0 == .survived },
            noCoverage: verdicts.count { $0 == .noCoverage },
            unviable: verdicts.count { $0 == .unviable },
            staleAccepted: ((acceptance?.staleMissing ?? []) + artifact.staleKilledAcceptances).sorted()
        )
        let gaps = artifact.results.filter { result in
            guard result.verdict == .survived || result.verdict == .noCoverage else { return false }
            return domain == .all || result.mutation.operatorID.domain.rawValue == domain.rawValue
        }
        let classification = ProjectLayout.discover(paths: [root]).map(ProjectClassification.load)
        var files: [String: LineIndex] = [:]
        var records: [Gap] = []
        for result in gaps {
            let mutation = result.mutation
            if files[mutation.path] == nil {
                let bytes = (try? BoundedFileReader.read(path: root + "/" + mutation.path, cap: 8 << 20)) ?? []
                files[mutation.path] = LineIndex(bytes)
            }
            let covering =
                classification?.testTargets(covering: SourcePath.canonical(root + "/" + mutation.path))
                .map(\.name) ?? []
            records.append(
                Gap(
                    id: mutation.id,
                    status: result.verdict.rawValue,
                    diagnostic: result.verdict == .noCoverage ? "not_reached" : "reached_not_detected",
                    domain: mutation.operatorID.domain.rawValue,
                    operator: mutation.operatorID.rawValue,
                    path: mutation.path,
                    line: mutation.line,
                    column: mutation.column,
                    declaration: mutation.declaration ?? "",
                    original: mutation.original,
                    replacement: mutation.replacement,
                    contextSnippet: files[mutation.path]?.excerpt(lines: mutation.line...mutation.endLine) ?? "",
                    reachingTests: (artifact.perTestReach?[mutation.id] ?? []).sorted(),
                    coveringModules: Array(Set(covering)).sorted(),
                    verifyCommand: verifyCommand(for: mutation, driver: artifact.provenance.driver)
                )
            )
        }
        records.sort { ($0.path, $0.line, $0.column, $0.id) < ($1.path, $1.line, $1.column, $1.id) }
        return Document(summary: summary, gaps: records)
    }

    /// The `litmus run` that re-verifies `mutation` alone, with the run's build selection, from the subject root.
    static func verifyCommand(for mutation: Mutation, driver: BuildDriver) -> String {
        var arguments = ["litmus", "run", "."]
        if let container = driver.container { arguments += ["--project", container] }
        if let packagePath = driver.packagePath { arguments += ["--package-path", packagePath] }
        if let scheme = driver.scheme { arguments += ["--scheme", scheme] }
        if let testPlan = driver.testPlan { arguments += ["--test-plan", testPlan] }
        if let destination = driver.destination { arguments += ["--destination", destination] }
        arguments += [
            "--operators", mutation.operatorID.rawValue, "--only-id", mutation.id, "--trust-project",
        ]
        // A fresh output directory each time: a run refuses one that exists.
        return arguments.map(shellQuoted).joined(separator: " ") + #" --output "$(mktemp -d)/run""#
    }

    /// `word` as one POSIX shell word: unchanged when it holds only safe characters, else single-quoted.
    static func shellQuoted(_ word: String) -> String {
        let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:,@%+")
        guard word.isEmpty || !word.allSatisfy(safe.contains) else { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
