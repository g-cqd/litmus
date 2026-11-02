internal import AemiIO
internal import Foundation
internal import SourceCorpus

/// Where a run builds and mutates (ADR 0007, design 0001 §2).
public enum WorkspaceStrategy: Sendable, Equatable {
    /// A fresh copy (APFS clones) in the run directory, built from scratch; the source is never written.
    case copy
    /// A Litmus-owned directory kept across runs: `<dir>/tree` synchronised from the source by manifest (unchanged files
    /// untouched, so builds are incremental), verified equal to the source before use; `<dir>/DerivedData` kept.
    case persistent(String)
    /// The subject root itself, for CI jobs that just built it: every original is backed up before it is rewritten
    /// and restored after each batch, on error, on signal, and at the start of any later run.
    case inPlace
}

/// An exclusive advisory lock on a file (`flock`), held until released or the process ends: two runs never share a
/// persistent or in-place workspace.
final class WorkspaceLock: Sendable {
    private let file: PosixFile

    init(path: String) throws {
        do {
            file = try PosixFile(path: path, mode: .readWrite(create: true))
        } catch {
            throw LitmusFailure("cannot open the workspace lock \(path): \(error)")
        }
        guard flock(file.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            file.close()
            throw LitmusFailure("another Litmus run holds \(path); one run per workspace")
        }
    }

    func release() { file.close() }
}

/// A workspace ready to build in, and how the run ends with it.
struct PreparedWorkspace {
    var snapshot: WorkspaceSnapshot
    /// The directory that holds `DerivedData` (Xcode); SwiftPM builds in `<workspace>/.build`.
    let buildDirectory: String
    let lock: WorkspaceLock?
    /// Only a copy is removed at the end; a persistent workspace is kept, and the subject root is never removed.
    let removable: Bool
    /// The in-place restore journal.
    let restore: InPlaceJournal?
    var notes: [String] = []

    /// Prepares `strategy` for `source`; `output` is the new run directory.
    static func prepare(
        _ strategy: WorkspaceStrategy,
        source: String,
        output: String,
        buildDirectory: String?
    ) async throws -> Self {
        switch strategy {
        case .copy:
            return Self(
                snapshot: try await WorkspaceSnapshot.create(source: source, destination: output + "/workspace"),
                buildDirectory: buildDirectory ?? output + "/artifacts",
                lock: nil,
                removable: true,
                restore: nil
            )
        case .persistent(let directory):
            let directory = canonicalNew(directory)
            guard directory != source, !directory.hasPrefix(source + "/"), !source.hasPrefix(directory + "/") else {
                throw LitmusFailure("the persistent workspace must be outside the subject root, and not contain it")
            }
            try PersistentWorkspace.claim(directory, source: source)
            let lock = try WorkspaceLock(path: directory + "/lock")
            do {
                let (snapshot, notes) = try await PersistentWorkspace.synchronize(source: source, directory: directory)
                return Self(
                    snapshot: snapshot,
                    buildDirectory: buildDirectory ?? directory,
                    lock: lock,
                    removable: false,
                    restore: nil,
                    notes: notes
                )
            } catch {
                lock.release()
                throw error
            }
        case .inPlace:
            try FileManager.default.createDirectory(
                atPath: source + "/" + InPlaceJournal.directoryName,
                withIntermediateDirectories: true
            )
            let lock = try WorkspaceLock(path: source + "/" + InPlaceJournal.directoryName + "/lock")
            do {
                let journal = InPlaceJournal(root: source)
                // A run that ended without restoring (a second signal, a crash) left records: restore them first.
                let recovered = try journal.restoreAll()
                let inputs = try await WorkspaceSnapshot.inventory(source)
                var snapshot = WorkspaceSnapshot(
                    sourceRoot: source,
                    root: source,
                    entries: inputs.entries,
                    digest: Digest.sha256(try ArtifactCodec.json(inputs.entries))
                )
                snapshot.skippedLinks = inputs.skippedLinks
                return Self(
                    snapshot: snapshot,
                    buildDirectory: buildDirectory ?? output + "/artifacts",
                    lock: lock,
                    removable: false,
                    restore: journal,
                    notes: recovered > 0
                        ? ["in place: \(recovered) file(s) left rewritten by an earlier run restored before starting"]
                        : []
                )
            } catch {
                lock.release()
                throw error
            }
        }
    }
}

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

/// The in-place restore journal (`<root>/.litmus/restore`): before a file is rewritten, its original bytes and a record
/// (path, original digest, schema digest) are written and synced; restoring puts back the original only over the
/// schema Litmus wrote. A file that holds neither was edited meanwhile: it is left alone, its original kept, and the
/// run says so.
final class InPlaceJournal: Sendable {
    static let directoryName = ".litmus"
    let root: String
    private var directory: String { root + "/" + Self.directoryName + "/restore" }

    init(root: String) { self.root = root }

    private struct Record: Codable {
        let path: String
        let original: String
        let schema: String
    }

    private func recordPath(_ relative: String) -> String {
        directory + "/" + Digest.sha256(Array(relative.utf8)).prefix(32) + ".json"
    }

    private func backupPath(_ digest: String) -> String { directory + "/" + digest + ".orig" }

    /// Rewrites `path` (absolute, under the root) with `schema`, after making its original recoverable.
    func rewrite(_ path: String, original: [UInt8], schema: [UInt8]) throws {
        guard path.hasPrefix(root + "/") else { throw LitmusFailure("in place: \(path) is outside the root") }
        let relative = String(path.dropFirst(root.count + 1))
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let originalDigest = Digest.sha256(original)
        let backup = backupPath(originalDigest)
        if !FileManager.default.fileExists(atPath: backup) {
            try AtomicFile.replace(at: backup, with: original, durability: .barrier)
        }
        let record = Record(path: relative, original: originalDigest, schema: Digest.sha256(schema))
        try AtomicFile.replace(at: recordPath(relative), with: try ArtifactCodec.json(record), durability: .barrier)
        // Only now is the file rewritten: whatever happens next, the record and the original are on storage.
        try AtomicFile.replace(at: path, with: schema, durability: .none)
    }

    /// Restores every recorded file; returns how many were rewritten back.
    /// - Throws: when a file holds neither the original nor the schema (edited meanwhile), after restoring the others;
    ///   its record and original stay for `litmus restore`.
    @discardableResult
    func restoreAll() throws -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return 0 }
        var restored = 0
        var conflicts: [String] = []
        var kept: Set<String> = []
        for name in names.sorted() where name.hasSuffix(".json") {
            let file = directory + "/" + name
            let record = try ArtifactCodec.decode(
                Record.self,
                bytes: try BoundedFileReader.read(path: file, cap: 1 << 20)
            )
            guard !record.path.hasPrefix("/"), !record.path.split(separator: "/").contains("..") else {
                throw LitmusFailure("in place: restore record \(name) names a path outside the root")
            }
            let target = root + "/" + record.path
            let current = (try? BoundedFileReader.read(path: target, cap: 64 << 20)).map(Digest.sha256)
            if current == record.schema {
                let original = try BoundedFileReader.read(path: backupPath(record.original), cap: 64 << 20)
                guard Digest.sha256(original) == record.original else {
                    conflicts.append("\(record.path) (its backup does not match its digest)")
                    kept.insert(record.original)
                    continue
                }
                try AtomicFile.replace(at: target, with: original, durability: .barrier)
                restored += 1
            } else if current != record.original {
                conflicts.append(record.path)
                kept.insert(record.original)
                continue
            }
            try fm.removeItem(atPath: file)
        }
        for name in (try? fm.contentsOfDirectory(atPath: directory)) ?? [] where name.hasSuffix(".orig") {
            if !kept.contains(String(name.dropLast(5))) { try? fm.removeItem(atPath: directory + "/" + name) }
        }
        guard conflicts.isEmpty else {
            throw LitmusFailure(
                "in place: \(conflicts.joined(separator: ", ")) changed since Litmus rewrote it; the original is kept in "
                    + "\(directory). Put it back by hand, then run `litmus restore \(root)`"
            )
        }
        return restored
    }

    /// The paths still recorded (rewritten and not yet restored).
    var outstanding: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).filter { $0.hasSuffix(".json") }
    }

    /// Removes the journal's directories when empty, leaving no trace in the subject.
    func tidy() {
        for path in [directory, root + "/" + Self.directoryName]
        where (try? FileManager.default.contentsOfDirectory(atPath: path))?.allSatisfy({ $0 == "lock" }) == true {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}

/// `litmus restore`: what an interrupted in-place run left rewritten, put back under the run's lock.
public enum InPlaceRestore {
    /// - Returns: how many files were restored.
    public static func restore(root: String) throws -> Int {
        let directory = root + "/" + InPlaceJournal.directoryName
        guard FileManager.default.fileExists(atPath: directory) else { return 0 }
        let lock = try WorkspaceLock(path: directory + "/lock")
        let journal = InPlaceJournal(root: root)
        defer {
            lock.release()
            journal.tidy()
        }
        return try journal.restoreAll()
    }
}
