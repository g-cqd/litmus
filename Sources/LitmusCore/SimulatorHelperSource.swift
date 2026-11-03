/// The source of the simulator test helper, compiled by Litmus for the simulator SDK (`SimulatorHelper`).
/// Kept in a raw string so `\(` in it stays Swift source.
let simulatorHelperSource = #"""
    // Litmus simulator test helper. Usage: helper <bundle binary> <events file> <configuration JSON>
    // Loads the test bundle, runs its Swift Testing tests through the versioned ABI entry point (records: JSON lines in the
    // events file, as `swift test --event-stream-output-path` writes them), then its XCTest cases through XCTestSuite with
    // an observer that writes one {"xctest":...} line per case to <events file>.xctest. Exit: 0 all passed, 1 a test
    // failed, 64 and above a setup problem (the caller then uses xcodebuild).
    import Darwin
    import Foundation
    import XCTest

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

    /// One JSON line per finished XCTest case.
    final class Observer: NSObject, XCTestObservation {
        let lines: Lines
        var failed: Set<String> = []
        init(_ lines: Lines) { self.lines = lines }
        func testCaseWillStart(_ testCase: XCTestCase) {
            // Marks where a stalled run stopped; a case that never finishes keeps its line without a result.
            record(testCase.name, "started")
        }
        func testCase(_ testCase: XCTestCase, didRecord issue: XCTIssueReference) { failed.insert(testCase.name) }
        func testCaseDidFinish(_ testCase: XCTestCase) {
            let skipped = testCase.testRun?.hasBeenSkipped == true
            record(testCase.name, failed.contains(testCase.name) ? "failed" : (skipped ? "skipped" : "passed"))
        }
        private func record(_ name: String, _ status: String) {
            if let line = try? JSONSerialization.data(withJSONObject: ["xctest": ["name": name, "status": status]]) {
                lines.emit(line)
            }
        }
    }

    @main enum Helper {
        /// Synchronous on purpose. XCTest runs `@MainActor` and `async` cases on the main thread and waits for them by
        /// running that thread's run loop. That works only from the main thread itself, outside any main-queue block (a
        /// block in progress is not re-entered by the nested run loop, so the case never gets its turn), and not off
        /// the main thread (a main-actor case traps there). Swift Testing runs in a task first, while the main thread
        /// services the main queue; XCTest then runs directly on the main thread.
        static func main() {
            let arguments = CommandLine.arguments
            guard arguments.count == 4 else { fail("usage: helper <bundle binary> <events> <configuration JSON>", 64) }
            guard dlopen(arguments[1], RTLD_NOW) != nil else { fail("dlopen: \(String(cString: dlerror()))", 65) }
            let lines = open(arguments[2])
            let xctestLines = open(arguments[2] + ".xctest")
            let configuration = Data(arguments[3].utf8)
            let options = (try? JSONSerialization.jsonObject(with: configuration) as? [String: Any]) ?? [:]
            let runsXCTest = options["xctest"] as? Bool ?? true
            // Observers are registered on the process's main thread, which XCTest requires.
            let observer = Observer(xctestLines)
            if runsXCTest { XCTestObservationCenter.shared.addTestObserver(observer) }
            nonisolated(unsafe) var swiftTestingPassed = false
            nonisolated(unsafe) var swiftTestingFinished = false
            Task.detached {
                do {
                    swiftTestingPassed = try await runSwiftTesting(configuration, lines)
                } catch {
                    fail("Swift Testing: \(error)", 68)
                }
                DispatchQueue.main.async { swiftTestingFinished = true }
            }
            // The main thread services the main queue (main-actor tests of Swift Testing) until Swift Testing is done.
            while !swiftTestingFinished { RunLoop.main.run(mode: .default, before: .distantFuture) }
            // XCTest then runs on the main thread, outside any main-queue block, as Xcode's runner does: its async and
            // main-actor cases spin this thread's run loop while they wait.
            let passed = swiftTestingPassed && (!runsXCTest || runXCTest(observer))
            lines.close()
            xctestLines.close()
            exit(passed ? 0 : 1)
        }

        /// Swift Testing through its versioned ABI entry point; its records go to `lines`.
        static func runSwiftTesting(_ configuration: Data, _ lines: Lines) async throws -> Bool {
            guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swt_abiv0_getEntryPoint") else {
                fail("no swt_abiv0_getEntryPoint: Swift Testing is not loaded", 67)
            }
            let getEntryPoint = unsafeBitCast(symbol, to: (@convention(c) () -> UnsafeRawPointer).self)
            let entryPoint = unsafeBitCast(getEntryPoint(), to: EntryPoint.self)
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: max(configuration.count, 1), alignment: 1)
            configuration.copyBytes(to: buffer)
            return try await entryPoint(UnsafeRawBufferPointer(rebasing: buffer[0..<configuration.count])) { record in
                lines.emit(Data(record))
            }
        }

        /// The bundle's XCTest cases; true when none failed.
        static func runXCTest(_ observer: Observer) -> Bool {
            let suite = XCTestSuite.default
            guard suite.testCaseCount > 0 else { return true }
            suite.run()
            return observer.failed.isEmpty
        }

        static func open(_ path: String) -> Lines {
            FileManager.default.createFile(atPath: path, contents: nil)
            guard let handle = FileHandle(forWritingAtPath: path) else { fail("cannot open \(path)", 66) }
            return Lines(handle)
        }

        static func fail(_ message: String, _ status: Int32) -> Never {
            fputs("litmus-helper: \(message)\n", stderr)
            exit(status)
        }
    }
    """#
