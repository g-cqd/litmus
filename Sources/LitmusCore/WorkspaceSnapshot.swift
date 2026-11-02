internal import Foundation
internal import SourceCorpus

/// The canonical spelling of a path that may not exist yet: its deepest existing ancestor canonicalized, then the rest.
/// `SourcePath.canonical` (Foundation's symlink resolution) drops the `/private` of `/private/tmp/x` only once `x`
/// exists, so a destination canonicalized before it is created would be spelled differently afterwards, and an
/// "outside the root" check could compare two spellings of one directory. Waiting for upstream: analyzerkit AK-18.
func canonicalNew(_ path: String) -> String {
    let absolute = SourcePath.canonical(path)
    var existing = absolute
    var rest: [String] = []
    while !FileManager.default.fileExists(atPath: existing), let slash = existing.lastIndex(of: "/"), existing != "/" {
        rest.insert(String(existing[existing.index(after: slash)...]), at: 0)
        existing = slash == existing.startIndex ? "/" : String(existing[..<slash])
    }
    let base = SourcePath.canonical(existing)
    return rest.isEmpty ? base : (base == "/" ? "" : base) + "/" + rest.joined(separator: "/")
}

/// One copied input and its cryptographic identity; resources/settings/tests are included, not only mutated files.
public struct SnapshotEntry: Codable, Sendable, Equatable {
    public let path: String
    public let sha256: String
}

/// An owned workspace with no shared source inodes. It is isolation against tool mistakes, not an OS security sandbox.
public struct WorkspaceSnapshot: Sendable {
    public let sourceRoot: String
    public let root: String
    public let entries: [SnapshotEntry]
    public let digest: String
    /// Links left out of the copy (never followed); a build that needed one fails, and the run's notes say which.
    public var skippedLinks: [String] = []
    /// What a snapshot copies and how far: at most 100,000 regular files of at most 128 MiB each, 8 GiB in total.
    static let limits: TreeSnapshot.Limits = {
        var limits = TreeSnapshot.Limits()
        limits.skippedNames = [".git", ".build", ".swiftpm", ".litmus", "DerivedData", "node_modules"]
        limits.maxEntries = 150_000
        limits.maxFiles = 100_000
        limits.maxFileBytes = 128 << 20
        limits.maxTotalBytes = 8 << 30
        limits.jobs = 8
        // A link is never followed or copied; it is left out and listed, so one editor link does not refuse the run.
        limits.links = .skip
        return limits
    }()

    /// Every regular file under `root` (skipped names pruned) with its SHA-256: analyzerkit's `TreeSnapshot`, on aemi's
    /// `DirectoryWalk`. A link is left out and listed, never followed; a special file is refused.
    static func currentEntries(_ root: String) async throws -> [SnapshotEntry] {
        try await inventory(root).entries
    }

    /// The entries under `root` and the links left out.
    static func inventory(_ root: String) async throws -> (entries: [SnapshotEntry], skippedLinks: [String]) {
        do {
            let manifest = try await TreeSnapshot.inventory(root, limits: limits)
            return (manifest.entries.map { SnapshotEntry(path: $0.path, sha256: $0.sha256) }, manifest.skippedLinks)
        } catch {
            throw LitmusFailure("inventory: \(error.reason)")
        }
    }

    /// Copies the tree with analyzerkit's `TreeSnapshot` (ADR-0030 there): files cloned where APFS allows, so the copy
    /// costs the hashing, not the bytes; links, special files and existing destinations refused; a partial copy
    /// removed on failure.
    /// - Important: Project execution remains trusted code execution; scripts may access paths outside this tree.
    public static func create(source: String, destination: String) async throws -> Self {
        let source = SourcePath.canonical(source), destination = canonicalNew(destination)
        let manifest: TreeSnapshot.Manifest
        do {
            manifest = try await TreeSnapshot.copy(from: source, to: destination, limits: limits).manifest
        } catch {
            throw LitmusFailure("snapshot \(error.reason)")
        }
        let inputs = manifest.entries.map { SnapshotEntry(path: $0.path, sha256: $0.sha256) }
        // The digest the run's provenance records and `analyze` checks: SHA-256 of the inputs' JSON, as before.
        let digest = Digest.sha256(try ArtifactCodec.json(inputs))
        var snapshot = Self(sourceRoot: source, root: destination, entries: inputs, digest: digest)
        snapshot.skippedLinks = manifest.skippedLinks
        return snapshot
    }

    /// Resolves a plan's path within this snapshot, rejecting traversal, aliases and symlink redirection.
    public func path(for relative: String) throws -> String {
        guard !relative.isEmpty, !relative.hasPrefix("/"),
            !relative.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
                $0 == ".." || $0 == "." || $0.isEmpty
            })
        else { throw LitmusFailure("invalid relative source path") }
        let spelled = root + "/" + relative
        guard SourcePath.canonical(spelled) == spelled,
            entries.contains(where: { $0.path == relative })
        else { throw LitmusFailure("source path is not a snapshot input: \(relative)") }
        return spelled
    }
}
