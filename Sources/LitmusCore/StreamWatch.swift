internal import Dispatch
internal import Foundation

#if canImport(Darwin)
    internal import Darwin
#endif

/// A supervision monitor that tails a file a test process is writing and stops the process at the first failure the
/// stream shows. On Darwin, once the file exists, watching uses a kernel `DispatchSourceFileSystemObject` (`kqueue`
/// `.extend`/`.write`/`.delete`/`.rename`, T-ECO-5) instead of a fixed-interval polling loop; on Linux (and while
/// waiting for the file to appear) it sleeps with bounded backoff.
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
    ///   - interval: Polling cadence while the file does not exist yet (and on non-Darwin hosts).
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
                #if canImport(Darwin)
                    let fd = unsafe Darwin.open(path, O_RDONLY | O_EVTONLY)
                    if fd >= 0 {
                        let done = await watchOpenFile(
                            path: path,
                            eventDescriptor: fd,
                            chunk: chunk,
                            bound: bound,
                            offset: &offset,
                            pending: &pending,
                            look: look,
                            stop: stop
                        )
                        if done { return }
                        continue
                    }
                #endif
                try? await Task.sleep(for: interval)
                if processStep(
                    path: path,
                    chunk: chunk,
                    bound: bound,
                    offset: &offset,
                    pending: &pending,
                    look: look,
                    stop: stop
                ) {
                    return
                }
            }
        }
    }

    /// Reads all newly appended bytes from `path`; returns `true` when watching should stop (failure seen or bound exceeded).
    private static func processStep(
        path: String,
        chunk: Int,
        bound: Int,
        offset: inout UInt64,
        pending: inout [UInt8],
        look: ([UInt8]) -> Look?,
        stop: (String) -> Void
    ) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil else { return true }
        while true {
            guard let bytes = try? handle.read(upToCount: chunk), !bytes.isEmpty else { return false }
            offset += UInt64(bytes.count)
            pending += bytes
            guard pending.count < bound, let seen = look(pending) else { return true }
            if seen.failed {
                stop(failFastReason)
                return true
            }
            pending.removeFirst(seen.consumed)
        }
    }

    #if canImport(Darwin)
        /// Waits on kernel vnode write/extend notifications for `path` (zero idle wakeups) until the stream fails,
        /// exceeds `bound`, is replaced/deleted, or the task is cancelled.
        private static func watchOpenFile(
            path: String,
            eventDescriptor: Int32,
            chunk: Int,
            bound: Int,
            offset: inout UInt64,
            pending: inout [UInt8],
            look: @escaping @Sendable ([UInt8]) -> Look?,
            stop: @escaping @Sendable (String) -> Void
        ) async -> Bool {
            let stream = AsyncStream<DispatchSource.FileSystemEvent> { continuation in
                let queue = DispatchQueue(label: "litmus.streamwatch.kqueue")
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: eventDescriptor,
                    eventMask: [.extend, .write, .delete, .rename],
                    queue: queue
                )
                source.setEventHandler { continuation.yield(source.data) }
                source.setCancelHandler { Darwin.close(eventDescriptor) }
                continuation.onTermination = { _ in source.cancel() }
                source.resume()
            }

            if processStep(
                path: path,
                chunk: chunk,
                bound: bound,
                offset: &offset,
                pending: &pending,
                look: look,
                stop: stop
            ) {
                return true
            }

            for await events in stream {
                if Task.isCancelled { return true }
                if processStep(
                    path: path,
                    chunk: chunk,
                    bound: bound,
                    offset: &offset,
                    pending: &pending,
                    look: look,
                    stop: stop
                ) {
                    return true
                }
                if events.contains(.delete) || events.contains(.rename) { return false }
            }
            return true
        }
    #endif
}
