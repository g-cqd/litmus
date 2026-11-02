internal import AemiFileSystem
internal import AemiRuntime
internal import Foundation
internal import SourceCorpus

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
    static let skipped: Set<String> = [".git", ".build", ".swiftpm", ".litmus", "DerivedData", "node_modules"]
    static let entryLimit = 150_000

    /// Every regular file under `root` (skipped names pruned), from aemi's `DirectoryWalk`: entry types from directory
    /// records, no link followed, bounded. A link or a special file is refused, never followed or dropped.
    /// - Returns: relative directories and files, sorted.
    static func inventory(_ root: String) throws -> (directories: [String], files: [String]) {
        let policy = DirectoryWalk.Policy(
            skippedNames: skipped,
            includesHidden: true,
            links: .never,
            reportsDirectories: true,
            limit: entryLimit + 1,
            workers: 4
        )
        try Task.checkCancellation()
        let walk = try DirectoryWalk.walk(root, policy: policy)
        guard !walk.limited, walk.entries.count <= entryLimit else {
            throw LitmusFailure("inventory entry limit exceeded")
        }
        guard walk.failures.isEmpty else {
            throw LitmusFailure("inventory could not read \(walk.failures.map(\.relativePath).joined(separator: ", "))")
        }
        var directories: [String] = [], files: [String] = []
        for entry in walk.entries {
            switch entry.kind {
            case .directory: directories.append(entry.relativePath)
            case .file: files.append(entry.relativePath)
            case .link: throw LitmusFailure("refusing symbolic link: \(entry.relativePath)")
            case .other: throw LitmusFailure("refusing special file: \(entry.relativePath)")
            }
        }
        guard files.count <= 100_000 else { throw LitmusFailure("snapshot file limit exceeded") }
        return (directories.sorted(), files.sorted())
    }

    /// The SHA-256 of every file of `files` under `root`, hashed in parallel with aemi's bounded `mapConcurrently`.
    static func hashes(_ files: [String], root: String) async throws -> [SnapshotEntry] {
        try await mapConcurrently(files, limit: 8) { relative in
            let bytes = try BoundedFileReader.read(path: root + "/" + relative, cap: 128 << 20)
            return SnapshotEntry(path: relative, sha256: Digest.sha256(bytes))
        }
    }

    /// Copies at most 100,000 regular files of at most 128 MiB each (8 GiB in total), in parallel; rejects links,
    /// special files and existing destinations; removes a partial copy on failure.
    /// - Important: Project execution remains trusted code execution; scripts may access paths outside this tree.
    public static func create(source: String, destination: String) async throws -> Self {
        let fm = FileManager.default
        let source = SourcePath.canonical(source), destination = SourcePath.canonical(destination)
        guard source != "/", destination != source, !destination.hasPrefix(source + "/"),
            !fm.fileExists(atPath: destination), fm.fileExists(atPath: source + "/")
        else { throw LitmusFailure("snapshot destination must be new and outside the source directory") }
        try fm.createDirectory(atPath: destination, withIntermediateDirectories: false)
        do {
            let (directories, files) = try inventory(source)
            for directory in directories {
                try fm.createDirectory(atPath: destination + "/" + directory, withIntermediateDirectories: false)
            }
            let entries = try await mapConcurrently(files, limit: 8) { relative -> (SnapshotEntry, Int) in
                let bytes = try BoundedFileReader.read(path: source + "/" + relative, cap: 128 << 20)
                let target = destination + "/" + relative
                // Independent data, never a hard link back to the source; no link is followed by this write.
                try Data(bytes).write(to: URL(fileURLWithPath: target), options: .withoutOverwriting)
                let attributes = try FileManager.default.attributesOfItem(atPath: source + "/" + relative)
                if let permissions = attributes[.posixPermissions] {
                    try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: target)
                }
                return (SnapshotEntry(path: relative, sha256: Digest.sha256(bytes)), bytes.count)
            }
            guard entries.reduce(0, { $0 + $1.1 }) <= 8 << 30 else { throw LitmusFailure("snapshot exceeds 8 GiB") }
            let inputs = entries.map(\.0)
            let digest = Digest.sha256(try ArtifactCodec.json(inputs))
            return Self(sourceRoot: source, root: destination, entries: inputs, digest: digest)
        } catch {
            do { try fm.removeItem(atPath: destination) } catch let cleanup {
                throw LitmusFailure("snapshot failed: \(error); cleanup also failed: \(cleanup)")
            }
            throw error
        }
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
