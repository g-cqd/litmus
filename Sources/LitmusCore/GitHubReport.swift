/// GitHub Actions workflow-command annotations (`analyze --format github`), capped at 50 per step.
public enum GitHubReport {
    public static func render(
        _ report: MutationReport,
        root: String? = nil,
        maxAnnotations: Int = 50
    ) -> String {
        let actionable = report.findings.filter { $0.severity == "error" || $0.severity == "warning" }
        let cap = max(0, maxAnnotations)
        var lines: [String] = []
        lines.reserveCapacity(min(actionable.count, cap) + 1)
        for finding in actionable.prefix(cap) {
            let level = finding.severity == "error" ? "error" : "warning"
            var path = finding.path
            if let root, path.hasPrefix(root + "/") {
                path = String(path.dropFirst(root.count + 1))
            }
            let title = escape("Litmus (\(finding.rule))", property: true)
            let fileProp = escape(path, property: true)
            let message = escape(finding.message, property: false)
            lines.append(
                "::\(level) file=\(fileProp),line=\(finding.line),col=\(finding.column),title=\(title)::\(message)"
            )
        }
        if actionable.count > cap {
            lines.append("::notice title=Litmus::\(actionable.count - cap) additional finding(s) omitted")
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    private static func escape(_ text: String, property: Bool) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for ch in text {
            switch ch {
            case "%": out += "%25"
            case "\r": out += "%0D"
            case "\n": out += "%0A"
            case "\r\n": out += "%0D%0A"
            case ":" where property: out += "%3A"
            case "," where property: out += "%2C"
            default: out.append(ch)
            }
        }
        return out
    }
}
