internal import AemiIO
internal import Foundation
public import ProjectModel
internal import SourceCorpus

/// What a pull-request run mutates: the sites on the lines a change adds or rewrites, and optionally the rest of the
/// files it touches. Read from a unified diff the caller gives (`--diff`), or from git
/// (`--diff-base`), with analyzerkit's `ChangedLines`.
public struct ChangeScope: Sendable {
    /// How far a change reaches.
    public enum Breadth: String, Codable, Sendable, CaseIterable {
        /// The sites whose expression overlaps a changed line.
        case lines
        /// Every site of a changed file, those on changed lines first.
        case files
    }

    /// The change, with paths relative to the subject root.
    public let changed: ChangedLines
    public let breadth: Breadth
    /// Where the change came from, as recorded in the plan.
    public let source: String
    /// SHA-256 of the diff's bytes.
    public let digest: String

    public init(changed: ChangedLines, breadth: Breadth, source: String, digest: String) {
        self.changed = changed
        self.breadth = breadth
        self.source = source
        self.digest = digest
    }

    /// The change in a unified diff file, its paths relative to `diffRoot` (default: the enclosing git work tree of
    /// `root`, else `root`), seen from `root`.
    public static func load(
        diffFile: String,
        root: String,
        diffRoot: String? = nil,
        strip: Int? = nil,
        breadth: Breadth
    ) throws -> Self {
        let bytes = try BoundedFileReader.read(path: diffFile, cap: ChangedLines.Limits().maxBytes)
        let changed: ChangedLines
        do { changed = try ChangedLines.parse(bytes, strip: strip) } catch { throw LitmusFailure("--diff: \(error)") }
        let root = SourcePath.canonical(root)
        let base = SourcePath.canonical(diffRoot ?? workTree(containing: root) ?? root)
        guard root == base || root.hasPrefix(base + "/") else {
            throw LitmusFailure("--diff-root \(base) does not contain the subject root \(root)")
        }
        let prefix = root == base ? "" : String(root.dropFirst(base.count + 1))
        return Self(
            changed: changed.rebased(onto: prefix),
            breadth: breadth,
            source: "diff file \(diffFile)",
            digest: Digest.sha256(bytes)
        )
    }

    /// The change from the merge base of `base` and `HEAD` to the working tree, from git: committed and uncommitted
    /// changes of tracked files (an untracked file is not in it until `git add -N`).
    public static func fromGit<Executor: ProcessExecutor>(
        base: String,
        root: String,
        breadth: Breadth,
        executor: Executor
    ) async throws -> Self {
        guard !base.hasPrefix("-"), !base.isEmpty, !base.contains("\0") else {
            throw LitmusFailure("--diff-base must name a git revision")
        }
        let output = try await executor.execute(
            ToolCommand(
                executable: "/usr/bin/xcrun",
                arguments: [
                    "git", "-c", "core.quotePath=true", "diff", "--merge-base", base, "--no-color", "--no-ext-diff",
                    "--no-textconv", "--unified=0", "--relative", "--src-prefix=a/", "--dst-prefix=b/", "--", ".",
                ]
            ),
            directory: root,
            environment: subjectEnvironment(nil),
            timeout: 120
        )
        guard output.exitStatus == 0, !output.timedOut, !output.truncated else {
            let message = String(decoding: output.stderr.prefix(400), as: UTF8.self)
            throw LitmusFailure(
                "git diff --merge-base \(base) failed (exit \(output.exitStatus)\(output.truncated ? ", truncated" : "")): "
                    + message.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        let changed: ChangedLines
        do { changed = try ChangedLines.parse(output.stdout, strip: 1) } catch {
            throw LitmusFailure("git diff output: \(error)")
        }
        return Self(
            changed: changed,
            breadth: breadth,
            source: "git diff --merge-base \(base)",
            digest: Digest.sha256(output.stdout)
        )
    }

    /// The nearest directory at or above `path` holding `.git` (a directory, or a file for worktrees).
    static func workTree(containing path: String) -> String? {
        var directory = path
        while true {
            if FileManager.default.fileExists(atPath: directory + "/.git") { return directory }
            guard let slash = directory.lastIndex(of: "/"), directory != "/" else { return nil }
            directory = slash == directory.startIndex ? "/" : String(directory[..<slash])
        }
    }

    /// The relative paths of the changed Swift files.
    public var swiftFiles: Set<String> { Set(changed.files.keys.filter { $0.hasSuffix(".swift") }) }

    /// 0 for a site on a changed line, 1 for another site of a changed file when the breadth is `files`; nil when out
    /// of scope.
    public func priority(of mutation: Mutation) -> Int? {
        if changed.contains(mutation.path, lines: mutation.line...mutation.endLine) { return 0 }
        return breadth == .files && changed.touches(mutation.path) ? 1 : nil
    }
}

/// The change a plan was scoped to, recorded with it.
public struct PlanScope: Codable, Sendable, Equatable {
    public let source: String
    public let digest: String
    public let breadth: ChangeScope.Breadth
    /// Changed files and lines in the subject, all kinds of files.
    public let changedFiles: Int
    public let changedLines: Int
    /// The changed Swift files the plan read.
    public let swiftFiles: Int
    /// The planned mutants on changed lines, which run first; the others are in changed files (breadth `files`).
    public let onChangedLines: [String]
}
