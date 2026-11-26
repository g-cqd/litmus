internal import Foundation

/// The JSON lines `xcodebuild -resultStreamPath` writes while tests run. The format is Xcode's own and not documented,
/// so it is read tolerantly and only to stop a run early: a line that is not understood is skipped, and a run whose
/// stream shows nothing simply runs its whole suite. Verdicts never depend on it; the result bundle's summary does.
enum XcodeResultStream {
    /// What the complete lines of `bytes` show.
    struct Scan: Equatable {
        /// A test finished with a failure.
        var failed = false
        /// The test host crashed and restarted mid-suite.
        var crashed = false
        /// The identifiers of the failed tests, in order.
        var failedTests: [String] = []
        /// Bytes up to the last complete line, which the next scan starts after.
        var consumed = 0
    }

    private static let finished = Array(#""_value":"testFinished""#.utf8)
    private static let failure = Array(#""testStatus":{"_type":{"_name":"String"},"_value":"Failure""#.utf8)
    private static let crashedNote = Array("Restarting after unexpected exit, crash, or test timeout".utf8)
    private static let crashedEarly = Array("Test runner never began executing tests after launching".utf8)

    static func scan(_ bytes: [UInt8]) -> Scan {
        var scan = Scan()
        var start = 0
        while let newline = bytes[start...].firstIndex(of: UInt8(ascii: "\n")) {
            let line = bytes[start..<newline]
            start = newline + 1
            scan.consumed = start
            if contains(line, crashedNote) || contains(line, crashedEarly) {
                scan.crashed = true
                continue
            }
            guard contains(line, finished), contains(line, failure) else { continue }
            scan.failed = true
            if let name = identifier(of: Array(line)) { scan.failedTests.append(name) }
        }
        return scan
    }

    private static func contains(_ line: ArraySlice<UInt8>, _ needle: [UInt8]) -> Bool {
        line.firstRange(of: needle) != nil
    }

    /// `test.identifier._value` of a `testFinished` line, or nil when the line has another shape.
    private static func identifier(of line: [UInt8]) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
            let payload = object["structuredPayload"] as? [String: Any], let test = payload["test"] as? [String: Any],
            let identifier = test["identifier"] as? [String: Any]
        else { return nil }
        return identifier["_value"] as? String
    }

    /// A supervision monitor that stops the run at the first failed test (when `failFast` holds) or host crash of the
    /// stream at `path`.
    static func monitor(
        path: String,
        failFast: Bool = true
    ) -> @Sendable (_ stop: @escaping @Sendable (String) -> Void) async -> Void {
        StreamWatch.monitor(path: path, interval: .milliseconds(50), chunk: 4 << 20, bound: 64 << 20) { pending in
            let seen = scan(pending)
            return StreamWatch.Look(failed: seen.crashed || (failFast && seen.failed), consumed: seen.consumed)
        }
    }
}
