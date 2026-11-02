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

    /// Copies at most 100,000 regular files and 8 GiB, rejecting links/special files and existing destinations.
    /// - Important: Project execution remains trusted code execution; scripts may access paths outside this tree.
    public static func create(source: String, destination: String) throws -> Self {
        let fm = FileManager.default
        let source = SourcePath.canonical(source), destination = SourcePath.canonical(destination)
        guard source != "/", destination != source, !destination.hasPrefix(source + "/"),
            !fm.fileExists(atPath: destination), fm.fileExists(atPath: source + "/")
        else { throw LitmusFailure("snapshot destination must be new and outside the source directory") }
        try fm.createDirectory(atPath: destination, withIntermediateDirectories: false)
        do {
            let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey]
            var enumerationFailed = false
            guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: source), includingPropertiesForKeys: Array(keys), errorHandler: { _, _ in
                enumerationFailed = true; return false
            }) else { throw LitmusFailure("cannot enumerate snapshot source") }
            var entries: [SnapshotEntry] = [], totalBytes: Int64 = 0, count = 0
            for case let url as URL in enumerator {
                try Task.checkCancellation()
                if skipped.contains(url.lastPathComponent) { enumerator.skipDescendants(); continue }
                count += 1
                guard count <= 150_000 else { throw LitmusFailure("snapshot entry limit exceeded") }
                let canonical = SourcePath.canonical(url.path)
                guard canonical.hasPrefix(source + "/") else { throw LitmusFailure("snapshot entry escapes source root") }
                let relative = String(canonical.dropFirst(source.count + 1))
                let target = URL(fileURLWithPath: destination).appendingPathComponent(relative)
                let values = try url.resourceValues(forKeys: keys)
                guard values.isSymbolicLink != true else { throw LitmusFailure("snapshot refuses symbolic link: \(relative)") }
                if values.isDirectory == true {
                    try fm.createDirectory(at: target, withIntermediateDirectories: false)
                } else {
                    guard values.isRegularFile == true, entries.count < 100_000 else { throw LitmusFailure("snapshot refuses special file or file limit exceeded: \(relative)") }
                    let bytes = try BoundedFileReader.read(path: url.path, cap: 128 << 20)
                    totalBytes += Int64(bytes.count)
                    guard totalBytes <= 8 << 30 else { throw LitmusFailure("snapshot exceeds 8 GiB") }
                    // Write independent data, never a hard link back to source. No symlink is followed by this write.
                    try Data(bytes).write(to: target, options: .atomic)
                    let attributes = try fm.attributesOfItem(atPath: url.path)
                    if let permissions = attributes[.posixPermissions] { try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path) }
                    entries.append(SnapshotEntry(path: relative, sha256: Digest.sha256(bytes)))
                }
            }
            guard !enumerationFailed else { throw LitmusFailure("snapshot enumeration failed") }
            entries.sort { $0.path < $1.path }
            let digest = Digest.sha256(try ArtifactCodec.json(entries))
            return Self(sourceRoot: source, root: destination, entries: entries, digest: digest)
        } catch {
            do { try fm.removeItem(atPath: destination) }
            catch let cleanup { throw LitmusFailure("snapshot failed: \(error); cleanup also failed: \(cleanup)") }
            throw error
        }
    }

    /// Resolves a plan's path within this snapshot, rejecting traversal, aliases and symlink redirection.
    public func path(for relative: String) throws -> String {
        guard !relative.isEmpty, !relative.hasPrefix("/"),
            !relative.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty })
        else { throw LitmusFailure("invalid relative source path") }
        let spelled = root + "/" + relative
        guard SourcePath.canonical(spelled) == spelled,
            entries.contains(where: { $0.path == relative }) else { throw LitmusFailure("source path is not a snapshot input: \(relative)") }
        return spelled
    }
}
