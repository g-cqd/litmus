internal import AemiIO
internal import Foundation
internal import SourceCorpus

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
