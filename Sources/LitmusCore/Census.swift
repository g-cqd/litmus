internal import AemiRuntime
internal import Foundation
internal import ProjectModel
internal import SourceCorpus
internal import SwiftOperators
internal import SwiftParser
internal import SwiftSyntax

/// Where a candidate operator's edit has to go, which decides whether one schema build can hold it.
public enum SchemaShape: String, Codable, Sendable {
    /// An expression replaced by an expression: `(m ? replacement : original)`, valid wherever the expression is.
    case expression
    /// A statement guarded or skipped: `if !m { statement }`; needs a statement context, never a result builder.
    case statement
    /// A pattern or clause that gains a `where`/guard condition: `case .a where !m:`, `for x in s where !m`.
    case clause
}

/// One candidate operator's sites in a corpus.
public struct CensusEntry: Codable, Sendable, Equatable {
    public let operatorID: String
    public let shape: SchemaShape
    /// Places the operator applies to.
    public var sites: Int
    /// Mutants generated: an operator may produce several variants per site (`<` → `<=`, `>=`).
    public var mutants: Int
    /// Sites skipped because the edit's context cannot hold it (a result builder for a statement operator).
    public var blocked: Int
}

extension CensusEntry {
    /// The operator `run` mutates this candidate with, when one exists; the rest only size future work.
    public var implementedBy: MutationOperator? {
        switch operatorID {
        case "negate-condition (current)": .negateCondition
        case "swap-ternary (current)": .swapTernary
        case "logical-replace (current)": .replaceLogical
        case "relational-equality", "relational-boundary-and-negation": .replaceRelational
        case "boolean-literal-flip": .flipBoolean
        case "arithmetic-replace", "compound-assignment-replace": .replaceArithmetic
        case "range-boundary": .replaceRange
        case "not-removal": .removeNegation
        case "nil-coalescing-to-default": .replaceNilCoalescing
        case "void-call-removal": .removeCall
        case "collection-method-swap": .replaceStdlibSemantic
        case "first-last-swap": .swapFirstLast
        case "collection-method-removal": .removeNormalization
        case "collection-transform-removal": .replaceCollectionTransform
        case "return-default-bool", "return-default-number", "return-default-string", "return-default-nil",
            "return-default-empty-collection":
            .returnConstant
        case "return-early-void": .emptyBody
        case "switch-case-skip (to default)": .removeSwitchCase
        case "optional-binding-to-nil": .nullifyOptionalBinding
        case "isEmpty-negation": .negateIsEmpty
        case "loop-skip (for … where)": .skipLoop
        case "break-continue-swap": .swapBreakContinue
        case "bitwise-replace": .replaceBitwise
        case "unary-minus-removal": .removeUnaryMinus
        case "defer-removal (fcheck)": .removeDefer
        case "cleanup-call-removal (fcheck)": .removeCleanupCall
        case "weak-capture-to-strong (arcleak)": .weakenCapture
        case "await-statement-swap (modeler)": .swapAsyncOrder
        default: nil
        }
    }
}

/// A syntax-only count of the sites candidate operators would mutate in a corpus's production files: no build, no
/// type information. It sizes operators before they are implemented; type errors are measured by the schema build.
public struct CensusReport: Codable, Sendable {
    public let root: String
    public let files: Int
    public let excludedFiles: Int
    public let degradedFiles: [String]
    public let entries: [CensusEntry]
}

public enum MutationCensus {
    /// Counts every candidate operator in the production files under `root`, with the planner's exclusions
    /// (tests, previews and debug-only code, generated code, files no target compiles, macro arguments).
    public static func run(root: String, exclude: [String] = [], jobs: Int = 8) async throws -> CensusReport {
        let root = SourcePath.canonical(root)
        let filter = PathFilter(exclude + ["Package.swift", "Dangerfile.swift", "**/Plugins/**"], root: root)
        let discovery = SourceDiscovery.discover(under: root, isExcluded: filter.excludes)
        guard !discovery.files.isEmpty else { throw LitmusFailure("no Swift source files under \(root)") }
        let classification = ProjectLayout.discover(paths: [root]).map(ProjectClassification.load) ?? .conventionsOnly
        enum Outcome: Sendable {
            case counted([String: CensusEntry])
            case excluded
            case degraded(String)
        }
        let outcomes = try await mapConcurrently(discovery.files, limit: min(max(jobs, 1), 16)) { path in
            await LargeStack.run { () -> Outcome in
                do {
                    switch try MutationPlanner.productionFile(path: path, classification: classification) {
                    case .excluded: return .excluded
                    case .production(let source, let tree):
                        return .counted(try count(source: source, tree: tree, path: path))
                    }
                } catch {
                    return .degraded(path)
                }
            }
        }
        var totals: [String: CensusEntry] = [:]
        var files = 0, excluded = 0
        var degraded: [String] = []
        for outcome in outcomes {
            switch outcome {
            case .counted(let entries):
                files += 1
                for (key, entry) in entries {
                    var total =
                        totals[key]
                        ?? CensusEntry(
                            operatorID: key,
                            shape: entry.shape,
                            sites: 0,
                            mutants: 0,
                            blocked: 0
                        )
                    total.sites += entry.sites
                    total.mutants += entry.mutants
                    total.blocked += entry.blocked
                    totals[key] = total
                }
            case .excluded: excluded += 1
            case .degraded(let path): degraded.append(path)
            }
        }
        return CensusReport(
            root: root,
            files: files,
            excludedFiles: excluded,
            degradedFiles: degraded.sorted(),
            entries: totals.values.sorted { ($0.mutants, $0.operatorID) > ($1.mutants, $1.operatorID) }
        )
    }

    /// Counts the candidate operators of one parsed file, outside preview and debug-only spans.
    static func count(source: String, tree: SourceFileSyntax, path: String) throws -> [String: CensusEntry] {
        let folded = try OperatorTable.standardOperators.foldAll(tree)
        let converter = SourceLocationConverter(fileName: path, tree: folded)
        let spans = CodeRegionScanner.scan(tree, converter: converter)
        let visitor = CensusVisitor(converter: converter, spans: spans)
        visitor.walk(folded)
        return visitor.entries
    }

    /// Counts one source text; for tests.
    public static func count(source: String) throws -> [String: CensusEntry] {
        try count(source: source, tree: Parser.parse(source: source), path: "census.swift")
    }
}
