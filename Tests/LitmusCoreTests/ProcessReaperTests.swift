import Foundation
import Testing

@testable import LitmusCore

/// A `KERN_PROCARGS2` record: argc, executable path, padding, arguments, environment.
private func procargs(arguments: [String], environment: [String]) -> ArraySlice<UInt8> {
    let argc = UInt32(arguments.count)
    var bytes: [UInt8] = [UInt8(argc & 0xFF), UInt8(argc >> 8 & 0xFF), UInt8(argc >> 16 & 0xFF), UInt8(argc >> 24)]
    bytes += Array("/bin/tool".utf8) + [0, 0, 0]
    for string in arguments + environment { bytes += Array(string.utf8) + [0] }
    return ArraySlice(bytes + [0])
}

@Test func `a token is found in the environment, never in the arguments`() {
    let entry = Array("LITMUS_PROCESS_TOKEN=abc".utf8)
    #expect(
        ProcessReaper.holds(
            procargs: procargs(arguments: ["tool"], environment: ["A=1", "LITMUS_PROCESS_TOKEN=abc"]),
            entry: entry
        )
    )
    #expect(
        !ProcessReaper.holds(
            procargs: procargs(arguments: ["tool", "LITMUS_PROCESS_TOKEN=abc"], environment: ["A=1"]),
            entry: entry
        )
    )
    #expect(
        !ProcessReaper.holds(
            procargs: procargs(arguments: ["tool"], environment: ["LITMUS_PROCESS_TOKEN=abcd"]),
            entry: entry
        )
    )
    #expect(!ProcessReaper.holds(procargs: ArraySlice([1, 0]), entry: entry))
}

/// Starts, through the real executor, a shell whose background child leaves the process group (as `swift test`'s
/// testing helper does), and returns the child's pid once the executor has returned.
private func escapedChild(shellTail: String, timeout: Int) async throws -> (pid_t, ProcessOutput) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("litmus-reaper-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pidFile = directory.appendingPathComponent("pid").path
    let script =
        "/usr/bin/perl -e 'setpgrp(0,0); open(F, \">\", \"\(pidFile)\"); print F $$; close F; sleep 600' & \(shellTail)"
    let output = try await BoundedExecutor().execute(
        ToolCommand(executable: "/bin/sh", arguments: ["-c", script]),
        directory: directory.path,
        environment: [:],
        timeout: timeout
    )
    let pid = pid_t(try String(contentsOfFile: pidFile, encoding: .utf8)) ?? 0
    return (pid, output)
}

/// Whether `pid` is gone; an orphan killed by SIGKILL is reaped by launchd shortly after.
private func gone(_ pid: pid_t) async throws -> Bool {
    for _ in 0..<50 {
        if kill(pid, 0) != 0, errno == ESRCH { return true }
        try await Task.sleep(for: .milliseconds(20))
    }
    return false
}

@Test func `a child that left the process group does not outlive a command that exited`() async throws {
    let (pid, output) = try await escapedChild(shellTail: "sleep 1; exit 0", timeout: 30)
    #expect(output.exitStatus == 0)
    #expect(pid > 1)
    #expect(try await gone(pid))
}

@Test func `a child that left the process group does not outlive a command that timed out`() async throws {
    let (pid, output) = try await escapedChild(shellTail: "sleep 600", timeout: 2)
    #expect(output.timedOut)
    #expect(pid > 1)
    #expect(try await gone(pid))
}

@Test func `the session trampoline passes arguments through unchanged`() async throws {
    let arguments = ["plain", "with space", "", "quote's \"double\"", "$HOME", "-c", "*"]
    let output = try await BoundedExecutor().execute(
        ToolCommand(executable: "/usr/bin/printf", arguments: ["%s\\n"] + arguments),
        directory: "/",
        environment: [:],
        timeout: 30
    )
    #expect(output.exitStatus == 0)
    #expect(String(decoding: output.stdout, as: UTF8.self) == arguments.map { $0 + "\n" }.joined())
}

@Test func `a missing executable is an error, as without the trampoline`() async throws {
    await #expect(throws: LitmusFailure.self) {
        try await BoundedExecutor().execute(
            ToolCommand(executable: "/nonexistent/litmus-tool", arguments: []),
            directory: "/",
            environment: [:],
            timeout: 30
        )
    }
}

/// An executable outside SIP (`/usr/bin/env` is protected, so dyld would strip DYLD_* from it whatever the shell did).
private let unprotectedPython = "/Applications/Xcode.app/Contents/Developer/usr/bin/python3"

@Test(.enabled(if: FileManager.default.isExecutableFile(atPath: unprotectedPython)))
func `DYLD variables reach the command through the SIP-protected shell`() async throws {
    let output = try await BoundedExecutor().execute(
        ToolCommand(
            executable: unprotectedPython,
            arguments: ["-c", "import os\nfor k, v in sorted(os.environ.items()): print(k + '=' + v)"]
        ),
        directory: "/",
        environment: ["DYLD_FRAMEWORK_PATH": "/a b/frameworks", "DYLD_LIBRARY_PATH": "/lib"],
        timeout: 30
    )
    let lines = String(decoding: output.stdout, as: UTF8.self).split(separator: "\n").map(String.init)
    #expect(lines.contains("DYLD_FRAMEWORK_PATH=/a b/frameworks"))
    #expect(lines.contains("DYLD_LIBRARY_PATH=/lib"))
    #expect(!lines.contains { $0.hasPrefix("LITMUS_TRAMPOLINE_") })
}
