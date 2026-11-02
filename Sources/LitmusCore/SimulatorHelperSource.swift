/// The source of the simulator test helper (t58), compiled by Litmus for the simulator SDK (`SimulatorHelper`).
/// Kept in a raw string so `\(` in it stays Swift source.
let simulatorHelperSource = #"""
    // Litmus simulator test helper (ADR 0007, t58). Usage: helper <bundle binary> <events file> <configuration JSON>
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
        func testCase(_ testCase: XCTestCase, didRecord issue: XCTIssueReference) { failed.insert(testCase.name) }
        func testCaseDidFinish(_ testCase: XCTestCase) {
            let status =
                failed.contains(testCase.name) ? "failed" : (testCase.testRun?.hasBeenSkipped == true ? "skipped" : "passed")
            if let line = try? JSONSerialization.data(withJSONObject: ["xctest": ["name": testCase.name, "status": status]]) {
                lines.emit(line)
            }
        }
    }

    @main enum Helper {
        static func main() async {
            let arguments = CommandLine.arguments
            guard arguments.count == 4 else { fail("usage: helper <bundle binary> <events> <configuration JSON>", 64) }
            guard dlopen(arguments[1], RTLD_NOW) != nil else { fail("dlopen: \(String(cString: dlerror()))", 65) }
            FileManager.default.createFile(atPath: arguments[2], contents: nil)
            guard let handle = FileHandle(forWritingAtPath: arguments[2]) else { fail("cannot open the events file", 66) }
            let lines = Lines(handle)
            FileManager.default.createFile(atPath: arguments[2] + ".xctest", contents: nil)
            guard let xctestHandle = FileHandle(forWritingAtPath: arguments[2] + ".xctest") else {
                fail("cannot open the XCTest events file", 66)
            }
            let xctestLines = Lines(xctestHandle)
            let configuration = Data(arguments[3].utf8)
            guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swt_abiv0_getEntryPoint") else {
                fail("no swt_abiv0_getEntryPoint: Swift Testing is not loaded", 67)
            }
            let getEntryPoint = unsafeBitCast(symbol, to: (@convention(c) () -> UnsafeRawPointer).self)
            let entryPoint = unsafeBitCast(getEntryPoint(), to: EntryPoint.self)
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: max(configuration.count, 1), alignment: 1)
            configuration.copyBytes(to: buffer)
            var passed: Bool
            do {
                passed = try await entryPoint(UnsafeRawBufferPointer(rebasing: buffer[0..<configuration.count])) { record in
                    lines.emit(Data(record))
                }
            } catch {
                fail("Swift Testing: \(error)", 68)
            }
            let options = (try? JSONSerialization.jsonObject(with: configuration) as? [String: Any]) ?? [:]
            if options["xctest"] as? Bool ?? true {
                let suite = XCTestSuite.default
                if suite.testCaseCount > 0 {
                    let observer = Observer(xctestLines)
                    XCTestObservationCenter.shared.addTestObserver(observer)
                    suite.run()
                    passed = passed && observer.failed.isEmpty
                }
            }
            lines.close()
            xctestLines.close()
            exit(passed ? 0 : 1)
        }

        static func fail(_ message: String, _ status: Int32) -> Never {
            fputs("litmus-helper: \(message)\n", stderr)
            exit(status)
        }
    }
    """#
