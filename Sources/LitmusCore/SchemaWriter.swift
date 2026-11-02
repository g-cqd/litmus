internal import Foundation
internal import SourceCorpus
internal import SwiftParser
internal import SwiftSyntax

/// The environment a schematised subject reads at startup; never changed while it runs.
public enum ActivationEnvironment {
    /// The mutant to activate; empty or absent activates none.
    public static let activeID = "LITMUS_ACTIVE_ID"
    /// A directory where the first evaluation of each mutant's site creates an empty file named after the mutant.
    public static let coverageDirectory = "LITMUS_COVERAGE_DIR"

    /// The mutant identifiers recorded in `directory`; files that are not identifiers are ignored.
    public static func reached(in directory: String) -> Set<String> {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        return Set(names.filter { $0.count == 16 && $0.allSatisfy(\.isHexDigit) })
    }
}

/// One schematised file and where each site landed in it.
public struct RenderedSchema: Sendable, Equatable {
    public let text: String
    /// 1-based line range of each mutant's replacement in `text`, to attribute compiler diagnostics.
    public let lines: [String: ClosedRange<Int>]
}

/// Builds conflict-free expression schemas. Edits are non-overlapping, preventing exponential nested duplication.
public enum SchemaWriter {
    /// Greedy deterministic batching, bounded by `limit` sites per compiled schema; each site appears once. Sites on the
    /// same range (`if a && b`: its negation and its operator swap) share a batch, chained in one replacement; sites
    /// that nest go to different batches.
    /// - Complexity: O(*n* · *b* · *k*) for *n* sites, *b* batches, *k* sites per batch.
    public static func batches(_ mutations: [Mutation], limit: Int = 64) -> [[Mutation]] {
        var result: [[Mutation]] = []
        for mutation in mutations.sorted(by: { ($0.path, $0.start, $0.id) < ($1.path, $1.start, $1.id) }) {
            if let index = result.firstIndex(where: { batch in
                batch.count < max(1, limit)
                    && !batch.contains { other in
                        other.path == mutation.path && other.start < mutation.end && mutation.start < other.end
                            && (other.start, other.end) != (mutation.start, mutation.end)
                    }
            }) {
                result[index].append(mutation)
            } else {
                result.append([mutation])
            }
        }
        return result
    }

    /// Renders one file's batch. See ``render(_:mutations:)``.
    public static func render(_ source: String, mutations: [Mutation]) throws -> String {
        try schema(source, mutations: mutations).text
    }

    /// Verifies source identity, byte ranges, unique IDs and overlap before performing any edit, then guards every
    /// site with its own once-initialised activation constant.
    ///
    /// Each mutant gets `@usableFromInline nonisolated internal let __litmus_<file>_<id>: Bool`, so a site may sit in a
    /// public default argument or an `@inlinable` body, under default actor isolation and strict memory safety. Its
    /// initialiser runs once per process: it records the activation in ``ActivationEnvironment/coverageDirectory`` and
    /// compares the startup selector, so the hot path is one Boolean load. In a file with top-level code (`main.swift`)
    /// the declarations precede the code, which initialises globals in order.
    public static func schema(_ source: String, mutations: [Mutation]) throws -> RenderedSchema {
        guard !mutations.isEmpty else { return RenderedSchema(text: source, lines: [:]) }
        let bytes = Array(source.utf8)
        let fingerprint = Digest.sha256(bytes)
        let sorted = mutations.sorted { ($0.start, $0.end, $0.id) < ($1.start, $1.end, $1.id) }
        guard Set(sorted.map(\.id)).count == sorted.count else { throw LitmusFailure("duplicate mutant IDs") }
        var previousEnd = 0
        var previousStart = -1
        for site in sorted {
            let sameRange = site.start == previousStart && site.end == previousEnd
            guard site.sourceFingerprint == fingerprint,
                sameRange || site.start >= previousEnd, site.end > site.start, site.end <= bytes.count,
                String(decoding: bytes[site.start..<site.end], as: UTF8.self) == site.original,
                site.id.count == 16, site.id.allSatisfy(\.isHexDigit)
            else { throw LitmusFailure("stale source or overlapping/invalid range for mutant \(site.id)") }
            previousStart = site.start
            previousEnd = site.end
        }
        let symbol = "__litmus_" + fingerprint.prefix(16)
        guard !source.contains(symbol) else { throw LitmusFailure("generated symbol collides with source") }
        let tree = Parser.parse(source: source)
        let placement = Placement(tree: tree, path: sorted[0].path)
        guard sorted[0].start >= placement.offset else {
            throw LitmusFailure("a mutant precedes the schema declarations of \(sorted[0].path)")
        }

        let declarations = runtime(
            symbol: symbol,
            ids: sorted.map(\.id),
            importsFoundation: placement.importsFoundation
        )
        let prefix: [UInt8] = placement.isTopLevelCode ? Array(("\n" + declarations).utf8) : []
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count + sorted.count * 96 + declarations.utf8.count)
        var ranges: [String: Range<Int>] = [:]
        var cursor = 0
        func copy(upTo offset: Int) {
            output.append(contentsOf: bytes[cursor..<offset])
            cursor = offset
        }
        copy(upTo: placement.offset)
        output.append(contentsOf: prefix)
        var groups: [[Mutation]] = []
        for site in sorted {
            if let last = groups.last?.last, (last.start, last.end) == (site.start, site.end) {
                groups[groups.count - 1].append(site)
            } else {
                groups.append([site])
            }
        }
        for group in groups {
            let first = group[0]
            copy(upTo: first.start)
            // `(m1 ? (r1) : m2 ? (r2) : (original))`: at most one activation holds in a process.
            var replacement = "("
            for site in group { replacement += "\(symbol)_\(site.id) ? (\(site.replacement)) : " }
            replacement += "(\(first.original)))"
            let start = output.count
            output.append(contentsOf: replacement.utf8)
            for site in group { ranges[site.id] = start..<output.count }
            cursor = first.end
        }
        copy(upTo: bytes.count)
        if !placement.isTopLevelCode { output.append(contentsOf: ("\n" + declarations).utf8) }
        let index = LineIndex(output)
        var lines: [String: ClosedRange<Int>] = [:]
        for (id, range) in ranges {
            guard let first = index.line(containingByte: range.lowerBound),
                let last = index.line(containingByte: max(range.lowerBound, range.upperBound - 1))
            else { throw LitmusFailure("cannot index the schema of \(sorted[0].path)") }
            lines[id] = first...last
        }
        return RenderedSchema(text: String(decoding: output, as: UTF8.self), lines: lines)
    }

    private static func runtime(symbol: String, ids: [String], importsFoundation: Bool) -> String {
        var text = "// litmus: generated mutation schema; this copy is never written back to the source tree\n"
        if !importsFoundation { text += "import Foundation\n" }
        text += """
            nonisolated private let \(symbol): Swift.String = \
            Foundation.ProcessInfo.processInfo.environment["\(ActivationEnvironment.activeID)"] ?? ""
            nonisolated private let \(symbol)_dir: Swift.String? = \
            Foundation.ProcessInfo.processInfo.environment["\(ActivationEnvironment.coverageDirectory)"]
            nonisolated private func \(symbol)_reach(_ id: Swift.String) -> Swift.Bool {
                if let directory = \(symbol)_dir {
                    _ = Foundation.FileManager.default.createFile(atPath: directory + "/" + id, contents: nil)
                }
                return \(symbol) == id
            }

            """
        for id in ids {
            text +=
                "@usableFromInline nonisolated internal let \(symbol)_\(id): Swift.Bool = \(symbol)_reach(\"\(id)\")\n"
        }
        return text
    }

    /// Where the declarations go, and whether the file already imports Foundation unconditionally.
    private struct Placement {
        let offset: Int
        let isTopLevelCode: Bool
        let importsFoundation: Bool

        init(tree: SourceFileSyntax, path: String) {
            var importsFoundation = false
            var afterImports = 0
            var sawCode = false
            var topLevelCode = path == "main.swift" || path.hasSuffix("/main.swift")
            for item in tree.statements {
                if let decl = item.item.as(ImportDeclSyntax.self) {
                    if decl.path.count == 1, decl.path.first?.name.text == "Foundation" { importsFoundation = true }
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
            self.importsFoundation = importsFoundation
            // A file without imports starts its declarations after a shebang line, if any.
            let text = tree.description.utf8
            if afterImports == 0, text.starts(with: "#!".utf8), let newline = text.firstIndex(of: UInt8(ascii: "\n")) {
                afterImports = text.distance(from: text.startIndex, to: newline) + 1
            }
            offset = topLevelCode ? afterImports : 0
        }
    }
}
