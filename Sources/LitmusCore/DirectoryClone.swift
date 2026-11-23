internal import Darwin
internal import Foundation

/// Copies a directory tree by APFS clone where the volume can (metadata only: the blocks are shared until either side
/// writes), and by copying otherwise.
enum DirectoryClone {
    /// `destination` must not exist; nothing is left behind when the copy fails.
    static func copy(from source: String, to destination: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            atPath: (destination as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let status = source.withCString { from in
            destination.withCString { to in unsafe clonefile(from, to, UInt32(CLONE_NOFOLLOW)) }
        }
        if status == 0 { return }
        try? fm.removeItem(atPath: destination)
        do { try fm.copyItem(atPath: source, toPath: destination) } catch {
            try? fm.removeItem(atPath: destination)
            throw LitmusFailure("cannot copy \(source) to \(destination): \(error)")
        }
    }
}
