internal import Foundation
internal import SourceCorpus
internal import SwiftParser
internal import SwiftSyntax

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

/// One schematised file and where each site landed in it.
public struct RenderedSchema: Sendable, Equatable {
    public let text: String
    /// 1-based line range of each mutant's replacement in `text`, to attribute compiler diagnostics.
    public let lines: [String: ClosedRange<Int>]
    /// Exact UTF-8 byte range of each mutant's own replacement branch in `text`, so column-bearing compiler errors on
    /// nested single-line schemas pinpoint the single offending mutant without bisecting its siblings/ancestors.
    public var branchBytes: [String: Range<Int>] = [:]
}

/// Builds conflict-free expression, statement and clause schemas. Nested sites are rendered inside-out (`RegionForest`)
/// up to `maxNestingDepth` per expression so non-overlapping and boundedly nested sites share one build.
public enum SchemaWriter {
    /// Maximum nesting depth of switches inside a single expression before spilling deeper sites into a subsequent
    /// schema batch, keeping type-checker work linear.
    public static let defaultMaxNestingDepth = 12

    /// Greedy deterministic batching, bounded by `limit` sites per compiled schema and `maxNestingDepth` nested switch
    /// levels per expression; each site appears once.
    /// - Complexity: O(*n* · *b* · *k*) for *n* sites, *b* batches, *k* sites per batch.
    public static func batches(
        _ mutations: [Mutation],
        limit: Int = 256,
        maxNestingDepth: Int = defaultMaxNestingDepth
    ) -> [[Mutation]] {
        var result: [[Mutation]] = []
        let sorted = mutations.sorted {
            ($0.path, $0.start, -$0.end, $0.id) < ($1.path, $1.start, -$1.end, $1.id)
        }
        for mutation in sorted {
            if let index = result.firstIndex(where: { batch in
                batch.count < max(1, limit)
                    && canPlace(mutation, in: batch, maxNestingDepth: max(1, maxNestingDepth))
            }) {
                result[index].append(mutation)
            } else {
                result.append([mutation])
            }
        }
        return result
    }

    private static func canPlace(_ candidate: Mutation, in batch: [Mutation], maxNestingDepth: Int) -> Bool {
        var ancestors = 0
        for other in batch where other.path == candidate.path {
            let sameRange = (other.start, other.end) == (candidate.start, candidate.end)
            if sameRange {
                // Only pure expression replacements may chain on the exact same byte range.
                if candidate.effectiveShape != .expression || other.effectiveShape != .expression {
                    return false
                }
                continue
            }
            let disjoint = other.end <= candidate.start || candidate.end <= other.start
            if disjoint { continue }
            // A clause site (`case .x:` gaining `where !m`) must not nest with another site inside its pattern.
            if candidate.effectiveShape == .clause || other.effectiveShape == .clause {
                return false
            }
            let otherContainsCandidate = other.start <= candidate.start && candidate.end <= other.end
            let candidateContainsOther = candidate.start <= other.start && other.end <= candidate.end
            // Partial overlap (neither range contains the other) cannot form a tree.
            guard otherContainsCandidate || candidateContainsOther else { return false }
            if otherContainsCandidate { ancestors += 1 }
        }
        guard ancestors < maxNestingDepth else { return false }
        // Verify that adding `candidate` does not push any existing descendant in `batch` past `maxNestingDepth`.
        for other in batch
        where other.path == candidate.path
            && candidate.start <= other.start && other.end <= candidate.end
            && (other.start, other.end) != (candidate.start, candidate.end)
        {
            let depth = batch.count {
                $0.path == other.path && $0.start <= other.start && other.end <= $0.end
                    && ($0.start, $0.end) != (other.start, other.end)
            }
            if depth + 1 >= maxNestingDepth { return false }
        }
        return true
    }

    /// Renders one file's batch. See ``render(_:mutations:)``.
    public static func render(_ source: String, mutations: [Mutation]) throws -> String {
        try schema(source, mutations: mutations).text
    }

    /// Verifies source identity, byte ranges, unique IDs and tree containment before performing any edit, splices
    /// nested switches from the inside out, and statically re-parses the resulting file with `SwiftParser` so no
    /// syntactically invalid schema ever reaches a build.
    ///
    /// The runtime helper uses `@_silgen_name` C declarations (`getenv`, `open`, `close`, `lseek`, `write`,
    /// `os_unfair_lock_*`) instead of injecting `import Foundation`, avoiding Swift 6 access-level conflicts with
    /// `internal import Foundation` or `private import Foundation` in other files of the module.
    /// - Parameters:
    ///   - token: the run's ``ActivationEnvironment`` token; empty reads the bare variable names.
    ///   - slots: each mutant's ``SharedControlPage`` counter slot, from the whole batch
    ///     (``SharedControlLayout/slots(for:)``); nil numbers this file's mutants alone.
    public static func schema(
        _ source: String,
        mutations: [Mutation],
        token: String = "",
        slots: [String: Int]? = nil
    ) throws -> RenderedSchema {
        guard !mutations.isEmpty else { return RenderedSchema(text: source, lines: [:]) }
        let bytes = Array(source.utf8)
        let fingerprint = Digest.sha256(bytes)
        let sorted = mutations.sorted { ($0.start, -$0.end, $0.id) < ($1.start, -$1.end, $1.id) }
        guard Set(sorted.map(\.id)).count == sorted.count else { throw LitmusFailure("duplicate mutant IDs") }
        for site in sorted {
            guard site.sourceFingerprint == fingerprint,
                site.start >= 0, site.end > site.start, site.end <= bytes.count,
                String(decoding: bytes[site.start..<site.end], as: UTF8.self) == site.original,
                site.id.count == 16, site.id.allSatisfy(\.isHexDigit)
            else { throw LitmusFailure("stale source or overlapping/invalid range for mutant \(site.id)") }
        }
        let forest = try RegionForest(mutations: sorted)
        let symbol = "__litmus_" + fingerprint.prefix(16)
        guard !source.contains(symbol) else { throw LitmusFailure("generated symbol collides with source") }
        let tree = Parser.parse(source: source)
        let placement = Placement(tree: tree, path: sorted[0].path)
        guard sorted[0].start >= placement.offset else {
            throw LitmusFailure("a mutant precedes the schema declarations of \(sorted[0].path)")
        }

        let slots = slots ?? SharedControlLayout.slots(for: sorted)
        let switches = try sorted.map(\.id).sorted().map { id in
            guard let slot = slots[id], (0..<SharedControlLayout.maximumSlots).contains(slot) else {
                throw LitmusFailure("mutant \(id) has no shared control slot")
            }
            return (id: id, slot: slot)
        }
        let declarations = runtime(symbol: symbol, switches: switches, token: token)
        let prefix: [UInt8] = placement.isTopLevelCode ? Array(("\n" + declarations).utf8) : []
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count + sorted.count * 96 + declarations.utf8.count)
        // A build-tool lint plugin (SwiftLint) must not fail the build over generated code it was not written for. A
        // shebang has to stay the first line.
        if !source.hasPrefix("#!") { output.append(contentsOf: Array("// swiftlint:disable all\n".utf8)) }
        var ranges: [String: Range<Int>] = [:]
        var branchBytes: [String: Range<Int>] = [:]
        output.append(contentsOf: bytes[0..<placement.offset])
        output.append(contentsOf: prefix)
        renderNodes(
            range: placement.offset..<bytes.count,
            children: forest.roots,
            bytes: bytes,
            symbol: symbol,
            into: &output,
            ranges: &ranges,
            branchBytes: &branchBytes
        )
        if !placement.isTopLevelCode { output.append(contentsOf: ("\n" + declarations).utf8) }
        let renderedText = String(decoding: output, as: UTF8.self)
        // Static verification: every rendered schema must parse without syntax errors before a build is started.
        let reparsed = Parser.parse(source: renderedText)
        guard !reparsed.hasError else {
            throw LitmusFailure("rendered schema for \(sorted[0].path) failed static syntax verification")
        }
        let index = LineIndex(output)
        var lines: [String: ClosedRange<Int>] = [:]
        for (id, range) in ranges {
            guard let first = index.line(containingByte: range.lowerBound),
                let last = index.line(containingByte: max(range.lowerBound, range.upperBound - 1))
            else { throw LitmusFailure("cannot index the schema of \(sorted[0].path)") }
            lines[id] = first...last
        }
        return RenderedSchema(text: renderedText, lines: lines, branchBytes: branchBytes)
    }

    private static func renderNodes(
        range: Range<Int>,
        children: [RegionNode],
        bytes: [UInt8],
        symbol: String,
        into output: inout [UInt8],
        ranges: inout [String: Range<Int>],
        branchBytes: inout [String: Range<Int>]
    ) {
        var cursor = range.lowerBound
        for child in children {
            output.append(contentsOf: bytes[cursor..<child.range.lowerBound])
            renderSwitch(
                child,
                bytes: bytes,
                symbol: symbol,
                into: &output,
                ranges: &ranges,
                branchBytes: &branchBytes
            )
            cursor = child.range.upperBound
        }
        output.append(contentsOf: bytes[cursor..<range.upperBound])
    }

    private static func renderSwitch(
        _ node: RegionNode,
        bytes: [UInt8],
        symbol: String,
        into output: inout [UInt8],
        ranges: inout [String: Range<Int>],
        branchBytes: inout [String: Range<Int>]
    ) {
        let first = node.mutations[0]
        let start = output.count
        switch first.effectiveShape {
        case .statement:
            // A statement (or body) is skipped when its mutant is active: `if !m { original-with-inner-switches }`.
            output.append(contentsOf: "if !\(symbol)_\(first.id) { ".utf8)
            renderNodes(
                range: node.range,
                children: node.children,
                bytes: bytes,
                symbol: symbol,
                into: &output,
                ranges: &ranges,
                branchBytes: &branchBytes
            )
            output.append(contentsOf: " }".utf8)
            ranges[first.id] = start..<output.count
            branchBytes[first.id] = start..<output.count
        case .clause:
            // A switch-case clause replacement already carries `\(Self.clauseGuardPlaceholder)` where `!\(symbol)_<id>`
            // goes.
            let expanded = first.replacement.replacingOccurrences(
                of: Self.clauseGuardPlaceholder,
                with: "!\(symbol)_\(first.id)"
            )
            output.append(contentsOf: expanded.utf8)
            ranges[first.id] = start..<output.count
            branchBytes[first.id] = start..<output.count
        case .expression:
            // `(m1 ? (r1) : m2 ? (r2) : (original-with-inner-switches))`: at most one activation holds in a process.
            output.append(contentsOf: "(".utf8)
            for site in node.mutations {
                let armStart = output.count
                output.append(contentsOf: "\(symbol)_\(site.id) ? (".utf8)
                output.append(contentsOf: site.replacement.utf8)
                output.append(contentsOf: ") : ".utf8)
                branchBytes[site.id] = armStart..<output.count
            }
            output.append(contentsOf: "(".utf8)
            renderNodes(
                range: node.range,
                children: node.children,
                bytes: bytes,
                symbol: symbol,
                into: &output,
                ranges: &ranges,
                branchBytes: &branchBytes
            )
            output.append(contentsOf: "))".utf8)
            let end = output.count
            for site in node.mutations { ranges[site.id] = start..<end }
        }
    }

    /// Placeholder token inside `remove-switch-case` replacements that `renderSwitch` expands to `!<symbol>_<id>`.
    public static let clauseGuardPlaceholder = "__LITMUS_CLAUSE_GUARD__"

    /// Emits the per-file runtime without adding `import Foundation`, using `@_silgen_name` C bindings for environment
    /// and marker/trace file I/O so files in modules with `internal import Foundation` or `private import Foundation`
    /// never suffer access-level import collisions.
    private static func runtime(symbol: String, switches: [(id: String, slot: Int)], token: String) -> String {
        func key(_ base: String) -> String { ActivationEnvironment.key(base, token: token) }
        let byteCount = SharedControlLayout.byteCount
        let magicIndex = SharedControlLayout.magic, magicValue = SharedControlLayout.magicValue
        let modeIndex = SharedControlLayout.mode, slotsIndex = SharedControlLayout.slots
        let headerWords = SharedControlLayout.headerWords, hitsIndex = SharedControlLayout.hits
        let isActiveIndex = SharedControlLayout.isActive, activeIndex = SharedControlLayout.active
        func helperBlock(strict: Bool) -> String {
            let atUnsafe = strict ? "@unsafe " : ""
            let kwUnsafe = strict ? "unsafe " : ""
            // SAFETY (the page): `words` is a mapping of the whole fixed layout, never unmapped, indexed only below it.
            let atSafe = strict ? "@safe " : ""
            return """
                \(atUnsafe)@_silgen_name("getenv") nonisolated private func \(symbol)_getenv(_ name: Swift.UnsafePointer<Swift.CChar>) -> Swift.UnsafeMutablePointer<Swift.CChar>?
                \(atUnsafe)@_silgen_name("open") nonisolated private func \(symbol)_open(_ path: Swift.UnsafePointer<Swift.CChar>, _ oflag: Swift.Int32, _ mode: Swift.UInt32) -> Swift.Int32
                @_silgen_name("close") nonisolated private func \(symbol)_close(_ fd: Swift.Int32) -> Swift.Int32
                \(atUnsafe)@_silgen_name("write") nonisolated private func \(symbol)_write(_ fd: Swift.Int32, _ buf: Swift.UnsafeRawPointer, _ nbyte: Swift.Int) -> Swift.Int
                \(atUnsafe)@_silgen_name("os_unfair_lock_lock") nonisolated private func \(symbol)_lock(_ lock: Swift.UnsafeMutablePointer<Swift.UInt32>)
                \(atUnsafe)@_silgen_name("os_unfair_lock_unlock") nonisolated private func \(symbol)_unlock(_ lock: Swift.UnsafeMutablePointer<Swift.UInt32>)
                \(atUnsafe)@_silgen_name("mmap") nonisolated private func \(symbol)_mmap(_ address: Swift.UnsafeMutableRawPointer?, _ length: Swift.Int, _ protection: Swift.Int32, _ flags: Swift.Int32, _ fd: Swift.Int32, _ offset: Swift.Int64) -> Swift.UnsafeMutableRawPointer?
                nonisolated private func \(symbol)_env(_ key: Swift.StaticString) -> Swift.String? {
                    key.withUTF8Buffer { buffer in
                        \(kwUnsafe)buffer.baseAddress.flatMap { base in
                            \(kwUnsafe)\(symbol)_getenv(Swift.UnsafeRawPointer(base).assumingMemoryBound(to: Swift.CChar.self))
                                .map { \(kwUnsafe)Swift.String(cString: $0) }
                        }
                    }
                }
                /// The shared control page (`SharedControlLayout`), when the run maps one; nil keeps `LITMUS_ACTIVE_ID`.
                \(atSafe)nonisolated private final class \(symbol)_Page: @unchecked Swift.Sendable {
                    private let words: Swift.UnsafeMutablePointer<Swift.UInt64>
                    private var rawLock: Swift.UInt32 = 0
                    private init(_ words: Swift.UnsafeMutablePointer<Swift.UInt64>) { \(kwUnsafe)self.words = words }
                    static func map() -> \(symbol)_Page? {
                        guard let path = \(symbol)_env("\(key(ActivationEnvironment.sharedControlPage))"), !path.isEmpty else { return nil }
                        var bytes = Swift.Array(path.utf8)
                        bytes.append(0)
                        let fd: Swift.Int32 = bytes.withUnsafeBufferPointer { buffer in
                            guard let base = buffer.baseAddress else { return -1 }
                            return \(kwUnsafe)\(symbol)_open(Swift.UnsafeRawPointer(base).assumingMemoryBound(to: Swift.CChar.self), 0x0002, 0)
                        }
                        guard fd >= 0 else { return nil }
                        defer { _ = \(symbol)_close(fd) }
                        guard let raw = \(kwUnsafe)\(symbol)_mmap(nil, \(byteCount), 3, 1, fd, 0), Swift.Int(bitPattern: raw) != -1 else { return nil }
                        let words = \(kwUnsafe)raw.assumingMemoryBound(to: Swift.UInt64.self)
                        guard \(kwUnsafe)words[\(magicIndex)] == \(magicValue) else { return nil }
                        return \(kwUnsafe)\(symbol)_Page(words)
                    }
                    /// Adds one to word `index` under this file's lock (a slot, or the hits only the active switch writes).
                    private func bump(_ index: Swift.Int) {
                        Swift.withUnsafeMutablePointer(to: &rawLock) { ptr in \(kwUnsafe)\(symbol)_lock(ptr) }
                        \(kwUnsafe)words[index] &+= 1
                        Swift.withUnsafeMutablePointer(to: &rawLock) { ptr in \(kwUnsafe)\(symbol)_unlock(ptr) }
                    }
                    /// Whether `id` is active; counts the evaluation in `slot` while the page asks for counts.
                    func check(_ id: Swift.UInt64, _ slot: Swift.Int) -> Swift.Bool {
                        if \(kwUnsafe)words[\(modeIndex)] & 1 != 0, slot < Swift.Int(truncatingIfNeeded: \(kwUnsafe)words[\(slotsIndex)]) {
                            bump(\(headerWords) + slot)
                        }
                        guard \(kwUnsafe)words[\(isActiveIndex)] != 0, \(kwUnsafe)words[\(activeIndex)] == id else { return false }
                        bump(\(hitsIndex))
                        return true
                    }
                }
                nonisolated private final class \(symbol)_Tracker: @unchecked Swift.Sendable {
                    private var rawLock: Swift.UInt32 = 0
                    private var touched = Swift.Set<Swift.String>()
                    private var traceFD: Swift.Int32 = -1
                    init() {
                        if let path = \(symbol)_trace, !path.isEmpty {
                            var bytes = Swift.Array(path.utf8)
                            bytes.append(0)
                            traceFD = bytes.withUnsafeBufferPointer { buffer in
                                guard let base = buffer.baseAddress else { return -1 }
                                return \(kwUnsafe)\(symbol)_open(
                                    Swift.UnsafeRawPointer(base).assumingMemoryBound(to: Swift.CChar.self),
                                    0x0009,
                                    0o644
                                )
                            }
                        }
                    }
                    func record(_ id: Swift.String, directory: Swift.String?) {
                        Swift.withUnsafeMutablePointer(to: &rawLock) { ptr in \(kwUnsafe)\(symbol)_lock(ptr) }
                        defer { Swift.withUnsafeMutablePointer(to: &rawLock) { ptr in \(kwUnsafe)\(symbol)_unlock(ptr) } }
                        if let directory, touched.insert(id).inserted {
                            var bytes = Swift.Array((directory + "/" + id).utf8)
                            bytes.append(0)
                            bytes.withUnsafeBufferPointer { buffer in
                                guard let base = buffer.baseAddress else { return }
                                let fd = \(kwUnsafe)\(symbol)_open(
                                    Swift.UnsafeRawPointer(base).assumingMemoryBound(to: Swift.CChar.self),
                                    0x0201,
                                    0o644
                                )
                                if fd >= 0 { _ = \(symbol)_close(fd) }
                            }
                        }
                        if traceFD >= 0 {
                            let line = Swift.Array(("{\\"litmusReach\\":\\"" + id + "\\"}\\n").utf8)
                            line.withUnsafeBytes { raw in
                                if let ptr = raw.baseAddress { _ = \(kwUnsafe)\(symbol)_write(traceFD, ptr, raw.count) }
                            }
                        }
                    }
                }
                """
        }
        var text = """
            // litmus: generated mutation schema; this copy is never written back to the source tree
            #if hasFeature(StrictMemorySafety)
            \(helperBlock(strict: true))
            #else
            \(helperBlock(strict: false))
            #endif
            nonisolated private let \(symbol): Swift.String = \(symbol)_env("\(key(ActivationEnvironment.activeID))") ?? ""
            nonisolated private let \(symbol)_dir: Swift.String? = \(symbol)_env("\(key(ActivationEnvironment.coverageDirectory))")
            nonisolated private let \(symbol)_trace: Swift.String? = \(symbol)_env("\(key(ActivationEnvironment.testTracePath))")
            nonisolated private let \(symbol)_tracker = \(symbol)_Tracker()
            nonisolated private let \(symbol)_tracks: Swift.Bool = \(symbol)_dir != nil || \(symbol)_trace != nil
            nonisolated private let \(symbol)_page: \(symbol)_Page? = \(symbol)_Page.map()
            @inline(__always) nonisolated private func \(symbol)_reach(_ id: Swift.String) -> Swift.Bool {
                \(symbol)_tracker.record(id, directory: \(symbol)_dir)
                return true
            }

            """
        for (id, slot) in switches {
            text += """
                nonisolated private let \(symbol)_on_\(id): Swift.Bool = \(symbol) == "\(id)"
                @usableFromInline nonisolated internal var \(symbol)_\(id): Swift.Bool {
                    if \(symbol)_tracks { _ = \(symbol)_reach("\(id)") }
                    if let page = \(symbol)_page { return page.check(0x\(id), \(slot)) }
                    return \(symbol)_on_\(id)
                }

                """
        }
        return text
    }

    /// Mutants on the same byte range merged into one node, arranged as a containment forest.
    private final class RegionNode {
        let range: Range<Int>
        var mutations: [Mutation]
        var children: [RegionNode] = []

        init(range: Range<Int>, mutations: [Mutation]) {
            self.range = range
            self.mutations = mutations
        }
    }

    private struct RegionForest {
        var roots: [RegionNode] = []

        init(mutations: [Mutation]) throws {
            var groups: [Range<Int>: [Mutation]] = [:]
            for site in mutations { groups[site.start..<site.end, default: []].append(site) }
            let sortedRanges = groups.keys.sorted {
                ($0.lowerBound, -$0.upperBound) < ($1.lowerBound, -$1.upperBound)
            }
            var nodes: [RegionNode] = []
            for range in sortedRanges {
                let items = (groups[range] ?? []).sorted { $0.id < $1.id }
                if items.count > 1, items.contains(where: { $0.effectiveShape != .expression }) {
                    throw LitmusFailure("a statement site shares its range: \(items[0].id)")
                }
                nodes.append(RegionNode(range: range, mutations: items))
            }
            var stack: [RegionNode] = []
            for node in nodes {
                while let top = stack.last,
                    !(top.range.lowerBound <= node.range.lowerBound && node.range.upperBound <= top.range.upperBound)
                {
                    guard node.range.lowerBound >= top.range.upperBound else {
                        throw LitmusFailure(
                            "stale source or overlapping/invalid range for mutant \(node.mutations[0].id)"
                        )
                    }
                    stack.removeLast()
                }
                if let parent = stack.last {
                    if parent.mutations[0].effectiveShape == .clause {
                        throw LitmusFailure("a clause site cannot contain inner mutants: \(parent.mutations[0].id)")
                    }
                    parent.children.append(node)
                } else {
                    roots.append(node)
                }
                stack.append(node)
            }
        }
    }

    /// Where the declarations go.
    private struct Placement {
        let offset: Int
        let isTopLevelCode: Bool

        init(tree: SourceFileSyntax, path: String) {
            var afterImports = 0
            var sawCode = false
            var topLevelCode = path == "main.swift" || path.hasSuffix("/main.swift")
            for item in tree.statements {
                if item.item.is(ImportDeclSyntax.self) {
                    if !sawCode { afterImports = item.endPosition.utf8Offset }
                    continue
                }
                sawCode = true
                switch item.item {
                case .stmt, .expr: topLevelCode = true
                case .decl: break
                }
            }
            self.isTopLevelCode = topLevelCode
            // A file without imports starts its declarations after a shebang line, if any.
            let text = tree.description.utf8
            if afterImports == 0, text.starts(with: "#!".utf8), let newline = text.firstIndex(of: UInt8(ascii: "\n")) {
                afterImports = text.distance(from: text.startIndex, to: newline) + 1
            }
            offset = topLevelCode ? afterImports : 0
        }
    }
}
