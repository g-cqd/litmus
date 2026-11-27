internal import Foundation
internal import SourceCorpus
internal import SwiftParser

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

    static func canPlace(_ candidate: Mutation, in batch: [Mutation], maxNestingDepth: Int) -> Bool {
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
}
