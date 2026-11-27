internal import Foundation

/// A pull request's step summary (`analyze --format github-summary`, for `$GITHUB_STEP_SUMMARY`): logic and UI scores,
/// their change from a previous run, the mutants that run detected and this one does not, and one collapsible diff per
/// undetected mutant.
public enum GitHubSummaryReport {
    public static func render(_ artifact: RunArtifact, previous: RunArtifact? = nil, limit: Int = 50) -> String {
        var lines = ["## Litmus mutation testing", ""]
        lines.append(scoreLine("Score", artifact.score, previous?.score))
        let domains = [
            ("Logic", artifact.logicScore, previous?.logicScore), ("UI", artifact.uiScore, previous?.uiScore),
        ]
        let split = domains.compactMap { name, score, before in score.map { "\(name) " + percent($0, before) } }
        if split.count == 2 { lines.append(split.joined(separator: " · ")) }
        lines.append("")
        let undetected = artifact.results.filter { $0.verdict == .survived || $0.verdict == .noCoverage }
            .sorted {
                ($0.mutation.path, $0.mutation.line, $0.mutation.id) < (
                    $1.mutation.path, $1.mutation.line, $1.mutation.id
                )
            }
        if let previous {
            let detectedBefore = Set(previous.results.filter { $0.verdict.isDetected }.map(\.mutation.id))
            let regressions = undetected.filter { detectedBefore.contains($0.mutation.id) }
            if !regressions.isEmpty {
                lines.append("### Detected before, undetected now (\(regressions.count))")
                lines.append("")
                lines += regressions.prefix(limit).map {
                    "- \(location($0)) \($0.mutation.operatorID.rawValue): \($0.verdict.rawValue)"
                }
                lines.append("")
            }
        }
        for (title, verdict) in [("Survivors", Verdict.survived), ("Not covered by any test", .noCoverage)] {
            let group = undetected.filter { $0.verdict == verdict }
            guard !group.isEmpty else { continue }
            lines += ["### \(title) (\(group.count))", ""]
            for result in group.prefix(limit) { lines += details(result) }
            if group.count > limit { lines += ["… and \(group.count - limit) more in the run's evidence.", ""] }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func scoreLine(_ name: String, _ score: MutationScore, _ before: MutationScore?) -> String {
        guard score.percent != nil else {
            return "**No score:** \(score.unresolved) mutant(s) without a resolved verdict."
        }
        return
            "**\(name) \(percent(score, before))** (\(score.detected) detected of \(score.detected + score.undetected))"
    }

    /// `87.5 %`, with the change in points from `before` when both have a score.
    static func percent(_ score: MutationScore, _ before: MutationScore?) -> String {
        guard let value = score.percent else { return "n/a" }
        guard let old = before?.percent else { return "\(format(value)) %" }
        let delta = (value - old) * 100
        let points = (delta.rounded()) / 100
        return "\(format(value)) % (\(points >= 0 ? "+" : "")\(format(points)) pts)"
    }

    static func details(_ result: MutationResult) -> [String] {
        let mutation = result.mutation
        let fence = (mutation.original + mutation.replacement).contains("```") ? "~~~" : "```"
        let removed = mutation.original.split(separator: "\n", omittingEmptySubsequences: false).map { "- \($0)" }
        let added = mutation.replacement.split(separator: "\n", omittingEmptySubsequences: false).map { "+ \($0)" }
        return [
            "<details><summary>\(location(result)) <code>\(html(mutation.operatorID.rawValue))</code></summary>",
            "",
            fence + "diff",
        ] + removed + added + [fence, "", html(result.reason), "", "</details>", ""]
    }

    static func location(_ result: MutationResult) -> String {
        "<code>\(html(result.mutation.path)):\(result.mutation.line)</code>"
    }

    static func html(_ text: String) -> String { markupSafe(text, ampersand: "&amp;", less: "&lt;", greater: "&gt;") }

    /// `text` with `&` first, then `<` and `>`, replaced.
    static func markupSafe(_ text: String, ampersand: String, less: String, greater: String) -> String {
        text.replacingOccurrences(of: "&", with: ampersand).replacingOccurrences(of: "<", with: less)
            .replacingOccurrences(of: ">", with: greater)
    }

    static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String((value * 100).rounded() / 100)
    }
}
