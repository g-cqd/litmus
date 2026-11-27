internal import Foundation
internal import SwiftSyntax

extension SchemaWriter {
    static func renderNodes(
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

    static func renderSwitch(
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

    /// Mutants on the same byte range merged into one node, arranged as a containment forest.
    final class RegionNode {
        let range: Range<Int>
        var mutations: [Mutation]
        var children: [RegionNode] = []

        init(range: Range<Int>, mutations: [Mutation]) {
            self.range = range
            self.mutations = mutations
        }
    }

    struct RegionForest {
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
    struct Placement {
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
