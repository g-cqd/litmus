internal import Foundation
internal import Synchronization

#if canImport(Darwin)
    internal import Darwin
#endif

/// Event-driven non-blocking FIFO line reader backed by `poll` and a wake pipe (zero spin-polling).
@safe final class FIFOLineReader: Sendable {
    enum Next: Sendable { case line(Data), timedOut, ended }

    private struct State {
        var closed = false
        var peerExited = false
        var reading = false
        var released = false
        var pending = Data()
    }

    private let descriptor: Int32
    private let wake: (read: Int32, write: Int32)
    private let state = Mutex(State())

    init?(descriptor: Int32) {
        var ends: [Int32] = [-1, -1]
        // SAFETY: `ends` is a 2-element stack array as required by `pipe(2)`.
        guard unsafe pipe(&ends) == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        for end in ends { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }
        self.descriptor = descriptor
        self.wake = (ends[0], ends[1])
    }

    deinit { close() }

    func signalPeerExited() {
        let shouldWake = state.withLock { s -> Bool in
            guard !s.closed, !s.peerExited else { return false }
            s.peerExited = true
            return true
        }
        if shouldWake { wakePoll() }
    }

    func close() {
        let (shouldWake, releaseNow) = state.withLock { s -> (Bool, Bool) in
            guard !s.closed else { return (false, false) }
            s.closed = true
            if s.reading { return (true, false) }
            s.released = true
            return (false, true)
        }
        if shouldWake { wakePoll() }
        if releaseNow { releaseDescriptors() }
    }

    func next(timeout: Int) async -> Next {
        await Task.detached { [self] in readLine(timeout: timeout) }.value
    }

    private func wakePoll() {
        var byte: UInt8 = 1
        // SAFETY: writes 1 stack byte to the owned wake pipe.
        _ = unsafe write(wake.write, &byte, 1)
    }

    private func releaseDescriptors() {
        Darwin.close(descriptor)
        Darwin.close(wake.read)
        Darwin.close(wake.write)
    }

    private func readLine(timeout: Int) -> Next {
        let entered = state.withLock { s -> Bool in
            guard !s.closed, !s.reading else { return false }
            s.reading = true
            return true
        }
        guard entered else { return .ended }
        defer {
            let releaseNow = state.withLock { s -> Bool in
                s.reading = false
                guard s.closed, !s.released else { return false }
                s.released = true
                return true
            }
            if releaseNow { releaseDescriptors() }
        }
        let deadline = ContinuousClock.now + .seconds(timeout)
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var wakeBuffer = [UInt8](repeating: 0, count: 16)
        while true {
            let step = state.withLock { s -> Next? in
                if s.closed { return .ended }
                if let newline = s.pending.firstIndex(of: 0x0A) {
                    defer { s.pending.removeSubrange(...newline) }
                    return .line(Data(s.pending[..<newline]))
                }
                return s.peerExited ? .ended : nil
            }
            if let step { return step }
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { return .timedOut }
            let ms = Int32(
                clamping: remaining.components.seconds * 1_000
                    + remaining.components.attoseconds / 1_000_000_000_000_000
            )
            var fds = [
                pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0),
                pollfd(fd: wake.read, events: Int16(POLLIN), revents: 0),
            ]
            // SAFETY: `fds` has 2 valid descriptors owned until `releaseDescriptors()`.
            let ready = unsafe poll(&fds, 2, max(1, ms))
            if ready == 0 { return .timedOut }
            if ready < 0 {
                if errno == EINTR { continue }
                return .ended
            }
            if fds[1].revents != 0 {
                _ = wakeBuffer.withUnsafeMutableBytes { unsafe Darwin.read(wake.read, $0.baseAddress, $0.count) }
            }
            while true {
                // SAFETY: `buffer` is owned for this call and `descriptor` is valid while `reading` is true.
                let count = buffer.withUnsafeMutableBytes {
                    unsafe Darwin.read(descriptor, $0.baseAddress, $0.count)
                }
                if count > 0 {
                    state.withLock { $0.pending.append(contentsOf: buffer[..<count]) }
                } else if count < 0, errno == EAGAIN || errno == EINTR {
                    break
                } else {
                    return .ended
                }
            }
        }
    }
}
