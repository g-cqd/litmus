internal import AemiIO
internal import Foundation

/// A persistent workspace (`--workspace persistent:<dir>`): marked, locked, synchronised by manifest and verified.
enum PersistentWorkspace {
    static let marker = "litmus-workspace.json"

    /// Refuses a directory that holds anything but a Litmus workspace; marks a new or empty one.
    static func claim(_ directory: String, source: String) throws {
        let fm = FileManager.default
        let markerPath = directory + "/" + marker
        if fm.fileExists(atPath: markerPath) { return }
        if fm.fileExists(atPath: directory) {
            let contents = try fm.contentsOfDirectory(atPath: directory)
            guard contents.isEmpty else {
                throw LitmusFailure(
                    "\(directory) is not empty and not a Litmus workspace (no \(marker)); refusing to write there"
                )
            }
        }
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let record = "{\"tool\":\"litmus\",\"version\":1,\"source\":\(String(reflecting: source))}\n"
        try AtomicFile.replace(at: markerPath, with: Array(record.utf8), durability: .barrier)
    }

    /// Makes `<directory>/tree` hold exactly the source's inputs: unchanged files are left alone (their times too, so
    /// the build directory stays valid), changed ones replaced, missing ones copied, extra ones removed; build state
    /// under skipped names (`.build`, `DerivedData`) is kept. Then the tree is inventoried again and must equal the
    /// source; when it does not, it is replaced by a fresh copy (and builds from scratch).
    static func synchronize(source: String, directory: String) async throws -> (WorkspaceSnapshot, [String]) {
        let tree = directory + "/tree"
        let fm = FileManager.default
        guard fm.fileExists(atPath: tree) else {
            return (
                try await WorkspaceSnapshot.create(source: source, destination: tree), ["persistent workspace created"]
            )
        }
        let wanted = try await WorkspaceSnapshot.inventory(source)
        let present = try await WorkspaceSnapshot.inventory(tree)
        let have = Dictionary(present.entries.map { ($0.path, $0.sha256) }, uniquingKeysWith: { first, _ in first })
        let want = Set(wanted.entries.map(\.path))
        var changed = 0, added = 0, removed = 0
        for entry in wanted.entries where have[entry.path] != entry.sha256 {
            let target = tree + "/" + entry.path
            if have[entry.path] == nil { added += 1 } else { changed += 1 }
            try fm.createDirectory(
                atPath: (target as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            // Beside the target, then renamed over it: the tree never holds half a file.
            let temporary = target + ".litmus-sync"
            try? fm.removeItem(atPath: temporary)
            do { try FileCopy.copy(from: source + "/" + entry.path, to: temporary) } catch {
                throw LitmusFailure("persistent workspace: cannot copy \(entry.path): \(error)")
            }
            // SAFETY: the two paths are bridged to C strings that live for the duration of the call.
            guard unsafe rename(temporary, target) == 0 else {
                throw LitmusFailure("persistent workspace: cannot replace \(entry.path) (errno \(errno))")
            }
        }
        for entry in present.entries where !want.contains(entry.path) {
            try fm.removeItem(atPath: tree + "/" + entry.path)
            removed += 1
            removeEmptyParents(of: entry.path, in: tree)
        }
        for link in present.skippedLinks {
            // Never followed: a link in the tree came from outside Litmus.
            try? fm.removeItem(atPath: tree + "/" + link)
        }
        let after = try await WorkspaceSnapshot.inventory(tree)
        guard after.entries == wanted.entries else {
            try fm.removeItem(atPath: tree)
            return (
                try await WorkspaceSnapshot.create(source: source, destination: tree),
                ["persistent workspace did not verify after synchronisation; replaced by a fresh copy"]
            )
        }
        var snapshot = WorkspaceSnapshot(
            sourceRoot: source,
            root: tree,
            entries: after.entries,
            digest: Digest.sha256(try ArtifactCodec.json(after.entries))
        )
        snapshot.skippedLinks = wanted.skippedLinks
        return (
            snapshot,
            [
                "persistent workspace synchronised and verified: \(changed) changed, \(added) added, \(removed) removed, "
                    + "\(wanted.entries.count - changed - added) unchanged"
            ]
        )
    }

    /// Removes the directories above `relative` that the removal left empty.
    private static func removeEmptyParents(of relative: String, in tree: String) {
        var parts = relative.split(separator: "/").dropLast()
        while !parts.isEmpty {
            let path = tree + "/" + parts.joined(separator: "/")
            guard (try? FileManager.default.contentsOfDirectory(atPath: path))?.isEmpty == true else { return }
            try? FileManager.default.removeItem(atPath: path)
            parts = parts.dropLast()
        }
    }
}
