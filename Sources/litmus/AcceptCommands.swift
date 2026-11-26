import AnalyzerCLI
import ArgumentParser
import Foundation
import LitmusCore

struct Accept: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract:
            "Accept a reviewed equivalent mutant in .litmus-accepted.json, with the reason, instead of a comment in the source."
    )
    @Argument(help: "The mutant: its id, an id prefix of 8+ hex digits, or path:line:operator.") var mutant: String
    @Option(help: "The run directory (or run.json) the mutant was reported in.") var from: String
    @Option(help: "Why it is equivalent: the invariant or algebra that proves it (10+ non-space characters).")
    var reason: String
    @Option(help: "Subject root holding the acceptance file.") var root: String = "."
    @Option(help: "Acceptance file (default: .litmus-accepted.json at the root).") var acceptedFile: String?
    @Flag(help: "Accept a mutant the run detected all the same.") var force = false

    mutating func run() async throws {
        let root = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        do {
            let (entry, path) = try AcceptedMutants.accept(
                mutant,
                run: from,
                root: root,
                file: acceptedFile,
                reason: reason,
                force: force,
                today: formatter.string(from: Date())
            )
            stderr("litmus: accepted \(entry.id) (\(entry.rule) on `\(entry.text)`) in \(path)")
        } catch { try fail(error, code: .usage) }
    }
}

struct Unaccept: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove a mutant's acceptance from .litmus-accepted.json."
    )
    @Argument(help: "The accepted mutant id.") var id: String
    @Option(help: "Subject root holding the acceptance file.") var root: String = "."
    @Option(help: "Acceptance file (default: .litmus-accepted.json at the root).") var acceptedFile: String?

    mutating func run() async throws {
        let root = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
        let removed: Bool
        do { removed = try AcceptedMutants.unaccept(id, root: root, file: acceptedFile) } catch {
            try fail(error, code: .usage)
        }
        guard removed else { try fail(LitmusFailure("\(id) is not accepted"), code: .usage) }
        stderr("litmus: \(id) is no longer accepted")
    }
}
