internal import Foundation
internal import SourceCorpus

/// The environment a schematised subject reads at startup; never changed while it runs.
///
/// Each name carries the run's token (`LITMUS_ACTIVE_ID_<token>`), so a subject whose tests start another Litmus run
/// (Litmus on itself, a wrapper tool) never hands the outer run's selection to the inner run's schemas. An empty token
/// keeps the bare names.
public enum ActivationEnvironment {
    /// The mutant to activate; empty or absent activates none.
    public static let activeID = "LITMUS_ACTIVE_ID"
    /// A directory where the first evaluation of each mutant's site creates an empty file named after the mutant.
    public static let coverageDirectory = "LITMUS_COVERAGE_DIR"
    /// Optional path to a per-test trace log where test runners and schema evaluations append ordered `T <test>` and
    /// `R <id>` lines during the baseline/control run (single-pass per-test reach).
    public static let testTracePath = "LITMUS_TEST_TRACE"
    /// Optional path to a ``SharedControlPage``: when set (and the page is valid), the active mutant is read from it at
    /// every switch evaluation instead of from `LITMUS_ACTIVE_ID` once, so one process can run many mutants.
    public static let sharedControlPage = "LITMUS_SHARED_MAP"

    /// `base` as the run with `token` spells it: `base_token`, or `base` for an empty token.
    public static func key(_ base: String, token: String) -> String { token.isEmpty ? base : base + "_" + token }

    /// The token of a run over the subject at `root`: the first 8 hex digits of the SHA-256 of its canonical path.
    /// Stable across runs of one subject, so a persistent build directory still compiles schemas incrementally.
    public static func token(for root: String) -> String {
        String(Digest.sha256(Array(SourcePath.canonical(root).utf8)).prefix(8))
    }

    /// The mutant identifiers recorded in `directory`; files that are not identifiers are ignored.
    public static func reached(in directory: String) -> Set<String> {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        return Set(names.filter { $0.count == 16 && $0.allSatisfy(\.isHexDigit) })
    }

    /// Parses a per-test trace file containing interleaved Swift Testing / XCTest start/end stderr lines (or
    /// `T <testName>` / `E <testName>` lines) and `__litmus_reach <mutantID>` (or `R <mutantID>`) reach lines.
    /// Any reach line recorded while a test is active is attributed to that test; records outside any test boundary
    /// are placed in `outside`.
    public static func parseTestTrace(
        _ bytes: [UInt8],
        knownTests: [String] = []
    ) -> (byMutant: [String: Set<String>], outside: Set<String>) {
        var byMutant: [String: Set<String>] = [:]
        var outside: Set<String> = []
        var currentTest: String?
        let text = String(decoding: bytes, as: UTF8.self)
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.replacingOccurrences(of: "XCTestOutputBarrier", with: "")
                .replacingOccurrences(of: "\u{200B}", with: "")
                .trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("__litmus_reach ") || line.hasPrefix("R ") {
                let prefixLen = line.hasPrefix("__litmus_reach ") ? 15 : 2
                let id = String(line.dropFirst(prefixLen)).trimmingCharacters(in: .whitespaces)
                guard id.count == 16, id.allSatisfy(\.isHexDigit) else { continue }
                if let currentTest {
                    byMutant[id, default: []].insert(currentTest)
                } else {
                    outside.insert(id)
                }
                continue
            }
            if line.hasPrefix("T ") {
                let name = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                currentTest = name.isEmpty ? nil : name
                continue
            }
            if line.hasPrefix("E ") {
                currentTest = nil
                continue
            }
            // XCTest: Test Case '-[Module.Class method]' started. / passed / failed
            if let start = line.range(of: "Test Case '-["),
                let end = line.range(of: "]' ", range: start.upperBound..<line.endIndex)
            {
                let spec = line[start.upperBound..<end.lowerBound]
                let state = line[end.upperBound...]
                if state.hasPrefix("started") {
                    currentTest = String(spec)
                } else if state.hasPrefix("passed") || state.hasPrefix("failed") || state.hasPrefix("skipped") {
                    currentTest = nil
                }
                continue
            }
            // Swift Testing: "◇ Test <name> started." / "✔ Test <name> passed after …"
            var trimmed = Substring(line)
            while let first = trimmed.unicodeScalars.first, !first.isASCII || first == " " {
                trimmed = trimmed.dropFirst()
            }
            if trimmed.hasPrefix("Test ") {
                let rest = trimmed.dropFirst(5)
                if rest.hasSuffix(" started.") {
                    let rawName = String(rest.dropLast(" started.".count))
                    currentTest = matchKnownTest(rawName, in: knownTests) ?? rawName
                } else if rest.contains(" passed after ") || rest.contains(" failed after ")
                    || rest.contains(" skipped")
                {
                    currentTest = nil
                }
            }
        }
        return (byMutant, outside)
    }

    private static func matchKnownTest(_ printed: String, in knownTests: [String]) -> String? {
        guard !knownTests.isEmpty else { return nil }
        let unquoted =
            printed.count >= 2 && printed.hasPrefix("\"") && printed.hasSuffix("\"")
            ? String(printed.dropFirst().dropLast()) : printed
        if let exact = knownTests.first(where: { $0 == printed || $0 == unquoted }) { return exact }
        return knownTests.first {
            $0.hasSuffix("." + printed) || $0.hasSuffix("/" + printed)
                || $0.hasSuffix(".`\(unquoted)`()") || $0.hasSuffix("/`\(unquoted)`()")
        }
    }
}
