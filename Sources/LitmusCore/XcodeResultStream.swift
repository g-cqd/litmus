internal import Foundation

/// The JSON lines `xcodebuild -resultStreamPath` writes while tests run. The format is Xcode's own and not documented,
/// so it is read tolerantly and only to stop a run early: a line that is not understood is skipped, and a run whose
/// stream shows nothing simply runs its whole suite. Verdicts never depend on it; the result bundle's summary does.
enum XcodeResultStream {
    /// What the complete lines of `bytes` show.
    struct Scan: Equatable {
        /// A test finished with a failure.
        var failed = false
        /// The identifiers of the failed tests, in order.
        var failedTests: [String] = []
        /// Bytes up to the last complete line, which the next scan starts after.
        var consumed = 0
    }

    private static let finished = Array(#""_value":"testFinished""#.utf8)
    private static let failure = Array(#""testStatus":{"_type":{"_name":"String"},"_value":"Failure""#.utf8)

    static func scan(_ bytes: [UInt8]) -> Scan {
        var scan = Scan()
        var start = 0
        while let newline = bytes[start...].firstIndex(of: UInt8(ascii: "\n")) {
            let line = bytes[start..<newline]
            start = newline + 1
            scan.consumed = start
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

    /// A supervision monitor that stops the run at the first failed test of the stream at `path` (which must exist).
    static func monitor(path: String) -> @Sendable (_ stop: @escaping @Sendable (String) -> Void) async -> Void {
        { stop in
            var offset: UInt64 = 0
            var pending: [UInt8] = []
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let handle = FileHandle(forReadingAtPath: path) else { continue }
                defer { try? handle.close() }
                guard (try? handle.seek(toOffset: offset)) != nil else { return }
                // Nothing yet (or nothing new) is not the end of the stream: Xcode writes it as the tests run.
                guard let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty else { continue }
                offset += UInt64(chunk.count)
                pending += chunk
                // A stream that grows past the bound is not being read usefully: stop watching.
                guard pending.count < 64 << 20 else { return }
                let seen = XcodeResultStream.scan(pending)
                if seen.failed {
                    stop(failFastReason)
                    return
                }
                pending.removeFirst(seen.consumed)
            }
        }
    }
}
