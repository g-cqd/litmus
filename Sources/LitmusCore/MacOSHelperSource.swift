internal import Foundation

/// The source of the macOS shared-process helper (`SharedProcessHarness`), compiled once per toolchain into Litmus's
/// cache. Kept in a raw string so `\(` in it stays Swift source.
let macOSHelperSource = #"""
    // Litmus shared-process helper for macOS test bundles: the serve loop of `helperServeSource`.
    // Usage: helper <test bundle binary> <subject output log> <commands FIFO> <replies FIFO>
    \#(helperCommonSource)
    \#(helperServeSource)

    @main enum Helper {
        static func main() {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.count == 4 else {
                fail("usage: helper <bundle binary> <subject output log> <commands FIFO> <replies FIFO>", 64)
            }
            serve(bundle: arguments[0], subjectLog: arguments[1], commands: arguments[2], replies: arguments[3])
        }
    }
    """#

/// The serve loop of the shared-process helpers (macOS and simulator), at file scope: loads a test bundle once, then
/// runs Swift Testing through its versioned ABI entry point once per command. Commands and replies, one JSON line each,
/// go through two FIFOs the host made, so the protocol works the same through `simctl spawn`. The subject gets
/// /dev/null as stdin and the log as stdout, so nothing a test prints can be read as a reply.
///   ready:   {"ready":true}                                  (after the bundle loaded)
///   command: {"configuration":{...},"events":"<file>"}      (Swift Testing's configuration JSON; events written there)
///   reply:   {"passed":true|false}
/// The end of the commands FIFO ends the helper. Exit 64 and above: a setup problem.
let helperServeSource = #"""
    func serve(bundle: String, subjectLog: String, commands commandsPath: String, replies repliesPath: String) -> Never {
        // The host opens the commands FIFO for writing first, then the replies FIFO for reading: the same order here.
        let commands = open(commandsPath, O_RDONLY)
        let replies = open(repliesPath, O_WRONLY)
        guard commands >= 0, replies >= 0 else { fail("cannot open the command FIFOs", 65) }
        let null = open("/dev/null", O_RDONLY)
        let log = open(subjectLog, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard null >= 0, log >= 0, dup2(null, 0) >= 0, dup2(log, 1) >= 0 else { fail("redirect failed", 65) }
        close(null)
        close(log)
        guard dlopen(bundle, RTLD_NOW) != nil else { fail("dlopen: \(String(cString: dlerror()))", 65) }
        let entryPoint = swiftTestingEntryPoint()
        let input = FileHandle(fileDescriptor: commands, closeOnDealloc: true)
        let output = FileHandle(fileDescriptor: replies, closeOnDealloc: true)
        // Its own process ID, so the host ends a hung helper inside a simulator (`simctl spawn` is a separate process).
        serveReply(output, ["ready": true, "pid": Int(getpid())])
        var pending: [UInt8] = []
        while let line = serveNextLine(input, &pending) {
            guard let command = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                let configuration = command["configuration"],
                let configurationData = try? JSONSerialization.data(withJSONObject: configuration),
                let events = command["events"] as? String
            else { fail("unreadable command", 66) }
            FileManager.default.createFile(atPath: events, contents: nil)
            guard let handle = FileHandle(forWritingAtPath: events) else { fail("cannot open \(events)", 66) }
            let lines = Lines(handle)
            nonisolated(unsafe) var passed = false
            nonisolated(unsafe) var finished = false
            Task.detached {
                do {
                    passed = try await runEntryPoint(entryPoint, configurationData, lines)
                } catch {
                    fail("Swift Testing: \(error)", 68)
                }
                DispatchQueue.main.async { finished = true }
            }
            // The main thread services the main queue (main-actor tests) until the run is done.
            while !finished { RunLoop.main.run(mode: .default, before: .distantFuture) }
            lines.close()
            fflush(stdout)
            serveReply(output, ["passed": passed])
        }
        exit(0)
    }

    /// The next line of `input` without its newline; nil at the end.
    func serveNextLine(_ input: FileHandle, _ pending: inout [UInt8]) -> [UInt8]? {
        while true {
            if let newline = pending.firstIndex(of: 0x0A) {
                let line = Array(pending[..<newline])
                pending.removeSubrange(...newline)
                return line
            }
            let chunk = input.availableData
            if chunk.isEmpty { return nil }
            pending += chunk
        }
    }

    func serveReply(_ output: FileHandle, _ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { fail("cannot encode", 66) }
        output.write(data + Data([0x0A]))
    }
    """#

/// What both helpers declare at file scope: Swift Testing's ABI entry point, how it is found and run, JSON lines
/// written from any thread, and the exit for setup problems. Interpolated into each helper's source.
let helperCommonSource = #"""
    import Darwin
    import Foundation

    typealias EntryPoint = @convention(thin) @Sendable (
        _ configurationJSON: UnsafeRawBufferPointer?,
        _ recordHandler: @escaping @Sendable (_ recordJSON: UnsafeRawBufferPointer) -> Void
    ) async throws -> Bool

    /// Appends JSON lines from any thread.
    final class Lines: @unchecked Sendable {
        private let handle: FileHandle
        private let lock = NSLock()
        init(_ handle: FileHandle) { self.handle = handle }
        func emit(_ bytes: Data) {
            lock.lock()
            defer { lock.unlock() }
            handle.write(bytes)
            handle.write(Data([0x0A]))
        }
        func close() { try? handle.close() }
    }

    /// Swift Testing's versioned ABI entry point, from the loaded test bundle (exit 67 without it).
    func swiftTestingEntryPoint() -> EntryPoint {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swt_abiv0_getEntryPoint") else {
            fail("no swt_abiv0_getEntryPoint: Swift Testing is not loaded", 67)
        }
        let getEntryPoint = unsafeBitCast(symbol, to: (@convention(c) () -> UnsafeRawPointer).self)
        return unsafeBitCast(getEntryPoint(), to: EntryPoint.self)
    }

    /// One Swift Testing run with `configuration` (its configuration JSON); its records go to `lines`.
    func runEntryPoint(_ entryPoint: EntryPoint, _ configuration: Data, _ lines: Lines) async throws -> Bool {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: max(configuration.count, 1), alignment: 1)
        defer { buffer.deallocate() }
        configuration.copyBytes(to: buffer)
        return try await entryPoint(UnsafeRawBufferPointer(rebasing: buffer[0..<configuration.count])) { record in
            lines.emit(Data(record))
        }
    }

    func fail(_ message: String, _ status: Int32) -> Never {
        fputs("litmus-helper: \(message)\n", stderr)
        exit(status)
    }
    """#

/// Builds the macOS shared-process helper once per toolchain into Litmus's cache (`~/Library/Caches/litmus`), keyed
/// by its source, the compiler and the architecture; a helper already there is used when it is trusted.
enum MacOSHelper {
    static func build(into directory: String, executor: some ProcessExecutor, logs: String) async throws -> String {
        let version = try await executor.execute(
            ToolCommand(executable: "/usr/bin/xcrun", arguments: ["--sdk", "macosx", "swiftc", "--version"]),
            directory: directory,
            environment: subjectEnvironment(nil),
            timeout: 120
        )
        guard version.exitStatus == 0 else { throw LitmusFailure("`xcrun swiftc --version` failed") }
        return try await HelperCache.helper(
            name: "macos-helper",
            label: "shared-process helper",
            source: macOSHelperSource,
            compiler: String(decoding: version.stdout, as: UTF8.self),
            directory: directory,
            executor: executor,
            logs: logs
        ) { source, output, _ in
            ["--sdk", "macosx", "swiftc", "-parse-as-library", "-swift-version", "5", "-O", source, "-o", output]
        }
    }
}
