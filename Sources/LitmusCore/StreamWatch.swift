internal import Foundation

/// A supervision monitor that tails a file a test process is writing and stops the process at the first failure the
/// stream shows. The two streams it serves (Swift Testing's events and Xcode's result stream) differ only in how they
/// are read.
enum StreamWatch {
    /// What one look at the unread bytes found.
    struct Look {
        /// A failing test is in the stream: stop the run.
        var failed: Bool
        /// Bytes at the start that are decided and need not be read again.
        var consumed: Int
    }

    /// - Parameters:
    ///   - path: The stream; it may not exist yet.
    ///   - interval: How often to look.
    ///   - chunk: The most read at once.
    ///   - bound: The most unread bytes kept; a stream that grows past it is not being read usefully, so watching stops
    ///     and the run is judged by its final evidence.
    ///   - look: Reads the unread bytes; nil when they cannot be read as this stream, which also stops watching.
    static func monitor(
        path: String,
        interval: Duration,
        chunk: Int,
        bound: Int,
        look: @escaping @Sendable ([UInt8]) -> Look?
    ) -> @Sendable (_ stop: @escaping @Sendable (String) -> Void) async -> Void {
        { stop in
            var offset: UInt64 = 0
            var pending: [UInt8] = []
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let handle = FileHandle(forReadingAtPath: path) else { continue }
                defer { try? handle.close() }
                guard (try? handle.seek(toOffset: offset)) != nil else { return }
                // An empty read is a stream not written yet, not the end of it.
                guard let bytes = try? handle.read(upToCount: chunk), !bytes.isEmpty else { continue }
                offset += UInt64(bytes.count)
                pending += bytes
                guard pending.count < bound, let seen = look(pending) else { return }
                if seen.failed {
                    stop(failFastReason)
                    return
                }
                pending.removeFirst(seen.consumed)
            }
        }
    }
}
