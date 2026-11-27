internal import AemiIO
internal import Foundation
internal import SourceCorpus

/// Where a run builds and mutates.
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

/// An exclusive advisory lock on a file (`AemiIO.FileLock`), held until released or the process ends: two runs never
/// share a persistent or in-place workspace. Explicitly calls `LOCK_UN` before `close` via `FileLock.release()`.
final class WorkspaceLock: Sendable {
    private let lock: FileLock

    init(path: String) throws {
        do {
            lock = try FileLock(path: path, mode: .exclusiveNonBlocking)
        } catch  where error.errno == EWOULDBLOCK || error.errno == EAGAIN {
            throw LitmusFailure("another Litmus run holds \(path); one run per workspace")
        } catch {
            throw LitmusFailure("cannot open the workspace lock \(path): \(error)")
        }
    }

    func release() { lock.release() }
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
