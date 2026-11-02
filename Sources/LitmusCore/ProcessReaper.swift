internal import Darwin

/// Finds and kills the processes a command left behind, wherever they went.
///
/// analyzerkit's `BoundedProcess` starts each child in a session of its own and, on a deadline or a cancellation,
/// kills that child's process group. That misses processes that leave the group: `swift test` starts
/// `swiftpm-testing-helper` in a new process group, so a timed-out mutant's endless loop kept two cores busy for
/// 2.5 hours after the run that timed it out (found 2026-11-02); a test host app on a simulator is started by the
/// simulator's launchd and is no descendant at all. Every command therefore carries a token in its environment
/// (the `.xctestrun` passes it on to simulator processes), and when the command ends, any process of this user still
/// holding the token is killed.
///
/// Two keys find them. The session: each command starts as `/bin/sh`, which records its pid (the session's id, since
/// the child leads a new session) and `exec`s the tool; `setpgrp` changes a process's group, not its session, so
/// `getsid` still finds the testing helper. The token: macOS hides the environment of Apple platform binaries from
/// `KERN_PROCARGS2` (measured: `/usr/bin/perl`, `/bin/sleep`), but not of the subject's own executables, so the
/// token finds a simulator's test host, which belongs to another session.
enum ProcessReaper {
    /// The environment variable carrying a command's token.
    static let tokenVariable = "LITMUS_PROCESS_TOKEN"

    /// The environment variable naming the file where the trampoline records the session's id.
    static let sessionFileVariable = "LITMUS_SESSION_FILE"

    /// Wraps a command so that it records its pid in `$LITMUS_SESSION_FILE`, then becomes the command (same pid).
    ///
    /// `/bin/sh` is SIP-protected, so dyld removes `DYLD_*` variables from it and from what it `exec`s (measured: the
    /// direct harness lost `DYLD_FRAMEWORK_PATH` and XCTest failed to load). They travel renamed and the script
    /// exports them again just before `exec`.
    static func trampoline(_ command: ToolCommand, environment: [String: String]) -> (ToolCommand, [String: String]) {
        var environment = environment
        var exports = ""
        for key in environment.keys.sorted() where key.hasPrefix("DYLD_") {
            guard
                key.utf8.allSatisfy({
                    $0 == UInt8(ascii: "_") || (0x30...0x39).contains($0) || (0x41...0x5A).contains($0)
                })
            else { continue }
            environment["LITMUS_TRAMPOLINE_" + key] = environment.removeValue(forKey: key)
            exports += #"export \#(key)="$LITMUS_TRAMPOLINE_\#(key)"; unset LITMUS_TRAMPOLINE_\#(key); "#
        }
        let script = exports + #"printf '%s' "$$" > "$LITMUS_SESSION_FILE" && exec "$0" "$@""#
        return (
            ToolCommand(executable: "/bin/sh", arguments: ["-c", script, command.executable] + command.arguments),
            environment
        )
    }

    /// Kills, with SIGKILL, every process of this user other than this one that belongs to `session` or whose
    /// environment holds `tokenVariable=token`, repeating while new ones appear (at most 8 rounds). Returns the
    /// processes killed.
    @discardableResult
    /// Only processes started at or after `since` (seconds since 1970) can hold the token; older ones are not read.
    static func reap(session: pid_t?, token: String, since: Int = 0) -> [pid_t] {
        let entry = Array("\(tokenVariable)=\(token)".utf8)
        let me = getpid(), mySession = getsid(0)
        var killed: [pid_t] = []
        for _ in 0..<8 {
            let found = processes().filter { process in
                let pid = process.pid
                guard pid != me, pid > 1 else { return false }
                if let session, session > 1, session != mySession, getsid(pid) == session { return true }
                return process.started >= since && environment(of: pid, holds: entry)
            }.map(\.pid)
            if found.isEmpty { break }
            for pid in found where kill(pid, SIGKILL) == 0 { killed.append(pid) }
        }
        return killed
    }

    /// A process of this user and when it started (seconds since 1970).
    struct Process: Sendable {
        let pid: pid_t
        let started: Int
    }

    /// The processes of this user.
    static func processes() -> [Process] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        for _ in 0..<4 {
            var size = 0
            // SAFETY: sysctl with a nil buffer only reports the size needed; mib is a live local array.
            guard unsafe sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
            size += size / 8
            // SAFETY: kinfo_proc is a C record holding kernel pointers; they are never dereferenced, only p_pid is read.
            let stride = unsafe MemoryLayout<kinfo_proc>.stride
            var entries = unsafe [kinfo_proc](repeating: kinfo_proc(), count: size / stride)
            var length = unsafe entries.count * stride
            // SAFETY: the buffer is an owned array of `entries.count` kinfo_proc values and `length` is its byte
            // size; sysctl writes at most `length` bytes and reports how many it wrote.
            let status = entries.withUnsafeMutableBytes { buffer in
                unsafe sysctl(&mib, UInt32(mib.count), buffer.baseAddress, &length, nil, 0)
            }
            if status == 0 {
                return unsafe entries.prefix(length / stride).map {
                    unsafe Process(pid: $0.kp_proc.p_pid, started: Int($0.kp_proc.p_un.__p_starttime.tv_sec))
                }
            }
            guard errno == ENOMEM else { return [] }
        }
        return []
    }

    /// Whether `pid`'s environment holds exactly `entry` (`NAME=value`). False when it cannot be read.
    static func environment(of pid: pid_t, holds entry: [UInt8]) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        // SAFETY: sysctl with a nil buffer only reports the size needed; mib is a live local array.
        guard unsafe sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 4, size <= 4 << 20 else {
            return false
        }
        var bytes = [UInt8](repeating: 0, count: size)
        // SAFETY: the buffer is an owned array of `size` bytes; sysctl writes at most `size` and reports the count.
        let status = bytes.withUnsafeMutableBytes { buffer in
            unsafe sysctl(&mib, UInt32(mib.count), buffer.baseAddress, &size, nil, 0)
        }
        guard status == 0, size > 4 else { return false }
        return holds(procargs: bytes.prefix(size), entry: entry)
    }

    /// Reads a `KERN_PROCARGS2` record (argc, executable path, padding, argc arguments, then the environment, each
    /// NUL-terminated) and says whether an environment string equals `entry`.
    static func holds(procargs: ArraySlice<UInt8>, entry: [UInt8]) -> Bool {
        guard procargs.count > 4 else { return false }
        let start = procargs.startIndex
        let argc =
            Int(procargs[start]) | Int(procargs[start + 1]) << 8 | Int(procargs[start + 2]) << 16
            | Int(procargs[start + 3]) << 24
        var index = start + 4
        func skipString() {
            while index < procargs.endIndex, procargs[index] != 0 { index += 1 }
        }
        func skipNULs() {
            while index < procargs.endIndex, procargs[index] == 0 { index += 1 }
        }
        skipString()  // executable path
        skipNULs()
        for _ in 0..<argc {
            skipString()
            index += 1
            guard index < procargs.endIndex else { return false }
        }
        while index < procargs.endIndex, procargs[index] != 0 {
            let begin = index
            skipString()
            if procargs[begin..<index].elementsEqual(entry) { return true }
            index += 1
        }
        return false
    }
}
