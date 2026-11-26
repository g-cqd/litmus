internal import AemiIO
internal import Foundation
public import ReportSupport
internal import SourceCorpus

/// Reviewed equivalent mutants kept out of the source, in `.litmus-accepted.json` (analyzerkit's `AcceptanceFile`):
/// planned mutants it accepts are suppressed like an inline `// @lm:accept`, and entries matching no planned mutant are
/// reported as stale.
public enum AcceptedMutants {
    /// The file's default name, at the subject root.
    public static let fileName = ".litmus-accepted.json"
    public static let tool = "litmus"

    /// The acceptance file at `path` (default: ``fileName`` at `root`); nil when the default file does not exist.
    /// - Throws: `LitmusFailure` for an explicit path that does not exist, or a file analyzerkit refuses.
    public static func load(root: String, path: String? = nil) throws -> (file: AcceptanceFile, path: String)? {
        let resolved = location(root: root, path: path)
        guard FileManager.default.fileExists(atPath: resolved) else {
            if path != nil { throw LitmusFailure("acceptance file \(resolved) does not exist") }
            return nil
        }
        let bytes = try BoundedFileReader.read(path: resolved, cap: AcceptanceFile.byteCap)
        do { return (try AcceptanceFile.decode(Data(bytes), tool: tool), resolved) } catch {
            throw LitmusFailure("\(resolved): \(error)")
        }
    }

    /// Where the acceptance file of `root` is: `path` (relative to `root` unless absolute) or ``fileName``.
    public static func location(root: String, path: String?) -> String {
        guard let path else { return root + "/" + fileName }
        return path.hasPrefix("/") ? path : root + "/" + path
    }

    /// The anchor a mutant is matched by when its id changed (an ordinal shift).
    public static func anchor(of mutation: Mutation) -> AcceptanceFile.Anchor {
        AcceptanceFile.Anchor(
            path: mutation.path,
            declaration: mutation.declaration ?? "",
            rule: mutation.operatorID.rawValue,
            text: mutation.original,
            replacement: mutation.replacement
        )
    }

    /// The entry accepting `mutation`.
    public static func entry(for mutation: Mutation, reason: String, addedAt: String) -> AcceptanceFile.Entry {
        AcceptanceFile.Entry(
            id: mutation.id,
            path: mutation.path,
            declaration: mutation.declaration ?? "",
            rule: mutation.operatorID.rawValue,
            text: mutation.original,
            replacement: mutation.replacement,
            reason: reason,
            addedAt: addedAt
        )
    }

    /// `plan` with the mutants `file` accepts suppressed (kept planned when `verify`, to find the stale ones), and
    /// the acceptance recorded. An entry is stale when its file was planned, or no longer exists, and no planned
    /// mutant matches it; an entry of a file this plan did not read (`--only-path`, a diff) is not judged.
    public static func apply(_ file: AcceptanceFile, path: String, to plan: MutationPlan, verify: Bool) -> MutationPlan
    {
        let matches = file.match(plan.mutations, id: \.id, anchor: anchor(of:))
        let plannedFiles = Set((plan.mutations + plan.suppressed).map(\.path))
        let stale = matches.stale.filter {
            plannedFiles.contains($0.path) || !FileManager.default.fileExists(atPath: plan.root + "/" + $0.path)
        }
        var notes = plan.notes
        for entry in stale {
            notes.append(
                PlanNote(
                    path: entry.path,
                    reason: "stale-missing: accepted \(entry.id) (\(entry.rule) on `\(entry.text)`) matches no planned "
                        + "mutant; remove it with `litmus unaccept \(entry.id)`"
                )
            )
        }
        var result = MutationPlan(
            root: plan.root,
            analyzedFiles: plan.analyzedFiles,
            mutations: verify ? plan.mutations : matches.remaining,
            suppressed: plan.suppressed + (verify ? [] : matches.accepted.map(\.item)),
            notes: notes
        )
        result.scope = plan.scope
        result.skipped = plan.skipped
        result.acceptance = AcceptanceRecord(
            file: path,
            accepted: Dictionary(
                matches.accepted.map { ($0.item.id, $0.entry.reason) },
                uniquingKeysWith: { first, _ in first }
            ),
            staleMissing: stale.map(\.id),
            verifying: verify
        )
        return result
    }
}

extension AcceptedMutants {
    /// Accepts the mutant `selector` names in the run at `run` (a run directory, or its `run.json`/`run.pb`), writing
    /// the acceptance file of `root`.
    /// - Parameters:
    ///   - force: accept a mutant the run detected (killed, crashed, timed out) all the same.
    ///   - today: `YYYY-MM-DD`, the entry's `addedAt`.
    /// - Returns: the entry written and the file's path.
    /// - Throws: `LitmusFailure` for a selector matching no mutant of the run or more than one, a detected mutant
    ///   without `force`, a weak reason, or an unwritable file.
    public static func accept(
        _ selector: String,
        run: String,
        root: String,
        file: String? = nil,
        reason: String,
        force: Bool = false,
        today: String
    ) throws -> (entry: AcceptanceFile.Entry, path: String) {
        let artifact = try ArtifactCodec.read(RunArtifact.self, path: runArtifactPath(run))
        let chosen = try MutationSelector.select(
            artifact.results.map(\.mutation),
            by: [MutationSelector(parsing: selector)]
        )
        guard chosen.count == 1, let mutation = chosen.first else {
            throw LitmusFailure("\(selector) names \(chosen.count) mutants of the run; accept them one id at a time")
        }
        if let verdict = artifact.results.first(where: { $0.mutation.id == mutation.id })?.verdict, verdict.isDetected,
            !force
        {
            throw LitmusFailure(
                "\(mutation.id) was \(verdict.rawValue) in that run: the tests already detect it (--force to accept anyway)"
            )
        }
        let path = location(root: root, path: file)
        let current = try load(root: root, path: FileManager.default.fileExists(atPath: path) ? path : nil)?.file
        let entry = entry(for: mutation, reason: reason, addedAt: today)
        let updated: AcceptanceFile
        do { updated = try (current ?? AcceptanceFile(tool: tool)).adding(entry) } catch {
            throw LitmusFailure("\(error)")
        }
        try AtomicFile.replace(at: path, with: [UInt8](try updated.encoded()), durability: .barrier)
        return (entry, path)
    }

    /// Removes the acceptance of `id` from the acceptance file of `root`; false when it held none.
    public static func unaccept(_ id: String, root: String, file: String? = nil) throws -> Bool {
        guard let current = try load(root: root, path: file) else { return false }
        let (updated, found) = current.file.removing(id: id)
        if found {
            try AtomicFile.replace(at: current.path, with: [UInt8](try updated.encoded()), durability: .barrier)
        }
        return found
    }

    /// `run.json` (or `run.pb`) of a run directory, or `path` itself when it names a file.
    static func runArtifactPath(_ path: String) -> String {
        let type = (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
        return type == .typeDirectory ? path + "/run.json" : path
    }
}

/// What a plan's acceptance file decided.
public struct AcceptanceRecord: Codable, Equatable, Sendable {
    /// The file read.
    public let file: String
    /// The accepted planned mutants, with each reason.
    public let accepted: [String: String]
    /// Entries matching no planned mutant of a file the plan read (their code changed or is gone).
    public let staleMissing: [String]
    /// Whether the accepted mutants ran anyway (`--verify-accepted`), to find those a test now detects.
    public let verifying: Bool
}

extension RunArtifact {
    /// With `--verify-accepted`: the accepted mutants a test now detects, whose entries should be removed.
    public var staleKilledAcceptances: [String] {
        guard let acceptance = plan.acceptance, acceptance.verifying else { return [] }
        return results.filter { acceptance.accepted[$0.mutation.id] != nil && $0.verdict.isDetected }
            .map(\.mutation.id).sorted()
    }
}
