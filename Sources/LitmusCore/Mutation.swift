internal import Foundation

/// How much evidence supports an operator; each tier includes the ones before it.
public enum OperatorTier: String, Codable, CaseIterable, Sendable, Comparable {
    /// The original operators: conditions, ternaries and logical connectives. The default.
    case stable
    /// Comparison, boolean-literal, arithmetic, range, nil-coalescing and negation operators; opt in with
    /// `--operator-tier standard`.
    case standard
    /// Statement removal, which changes control flow and so needs the most review of its survivors.
    case experimental

    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// Which category of code an operator targets, so UI-only operators stay out of default tier selection and can be
/// reported separately from logic scores.
public enum OperatorDomain: String, Codable, Sendable {
    case logic
    case ui
}

/// The operators and their persistent rule identifiers (raw values), which suppression directives
/// (`// @lm:accept:next replace-relational`), baselines and result stores name.
public enum MutationOperator: String, Codable, CaseIterable, Sendable {
    case negateCondition = "negate-condition"
    case swapTernary = "swap-ternary"
    case replaceLogical = "replace-logical"
    case replaceRelational = "replace-relational"
    case flipBoolean = "flip-boolean"
    case replaceArithmetic = "replace-arithmetic"
    case replaceRange = "replace-range"
    case removeNegation = "remove-negation"
    case replaceNilCoalescing = "replace-nil-coalescing"
    case removeCall = "remove-call"
    case removeViewElement = "remove-view-element"
    case replaceStdlibSemantic = "replace-stdlib-semantic"
    case removeNormalization = "remove-normalization"
    case replaceOptionalChain = "replace-optional-chain"
    case returnBoundary = "return-boundary"
    case returnConstant = "return-constant"
    case emptyBody = "empty-body"
    case emptyClosureBody = "empty-closure-body"
    case removeSwitchCase = "remove-switch-case"

    /// The kind of edit it makes, which decides how its schema is written.
    public var shape: SchemaShape {
        switch self {
        case .removeCall, .removeViewElement, .emptyBody, .emptyClosureBody: .statement
        case .removeSwitchCase: .clause
        default: .expression
        }
    }

    public var tier: OperatorTier {
        switch self {
        case .negateCondition, .swapTernary, .replaceLogical: .stable
        case .replaceRelational, .flipBoolean, .replaceArithmetic, .replaceRange, .removeNegation,
            .replaceNilCoalescing:
            .standard
        case .removeCall, .removeViewElement, .replaceStdlibSemantic, .removeNormalization, .replaceOptionalChain,
            .returnBoundary, .returnConstant, .emptyBody, .emptyClosureBody, .removeSwitchCase:
            .experimental
        }
    }

    /// Whether this operator mutates program logic or declarative UI trees. UI operators are explicit opt-in via
    /// `--operators` so they never dilute a unit-test suite's logic mutation score.
    public var domain: OperatorDomain {
        switch self {
        case .removeViewElement: .ui
        default: .logic
        }
    }

    /// Whether this operator is included in automatic `--operator-tier` selection. Extended operators stay opt-in via
    /// `--operators` so existing tier baselines and policies stay stable until opted in.
    public var inDefaultTiers: Bool {
        switch self {
        case .negateCondition, .swapTernary, .replaceLogical, .replaceRelational, .flipBoolean, .replaceArithmetic,
            .replaceRange, .removeNegation, .replaceNilCoalescing, .removeCall:
            true
        case .removeViewElement, .replaceStdlibSemantic, .removeNormalization, .replaceOptionalChain, .returnBoundary,
            .returnConstant, .emptyBody, .emptyClosureBody, .removeSwitchCase:
            false
        }
    }

    /// One line for `--help` and reports.
    public var summary: String {
        switch self {
        case .negateCondition: "negate an if, guard or while condition"
        case .swapTernary: "negate the condition of a ternary (swap its branches)"
        case .replaceLogical: "exchange && and ||"
        case .replaceRelational: "shift comparison boundaries and negate comparisons (< <= > >= == !=)"
        case .flipBoolean: "flip true and false literals"
        case .replaceArithmetic: "exchange + and -, * and /, % to *, and compound assignments (+= -= *= /= %=)"
        case .replaceRange: "shift range upper bounds (a..<b to a..<(b+1), a...b to a...(b-1))"
        case .removeNegation: "remove unary logical negation (!x to x) outside conditions"
        case .replaceNilCoalescing: "replace nil-coalescing (a ?? b) with its fallback (b)"
        case .removeCall: "skip a call statement whose result is unused"
        case .removeViewElement: "skip a leaf SwiftUI view-builder element (explicit opt-in)"
        case .replaceStdlibSemantic:
            "swap standard-library semantic pairs (min/max, allSatisfy/contains, prefix/dropLast, dropFirst/suffix, hasPrefix/hasSuffix)"
        case .removeNormalization:
            "remove String normalization calls (.lowercased(), .uppercased(), .trimmingCharacters(in:))"
        case .replaceOptionalChain: "unwrap an optional-chained expression (a?.b to a!.b)"
        case .returnBoundary: "shift or empty a returned value in a typed function (n + 1, \"\", [])"
        case .returnConstant: "replace a returned value with a boundary constant (0, 1, nil, true, false)"
        case .emptyBody: "skip the body of a Void-returning function or method"
        case .emptyClosureBody: "skip the body of a trailing Void closure (excluding lock/sync wrappers)"
        case .removeSwitchCase: "guard a non-default switch case so it falls through to default"
        }
    }

    /// The logic operators of `tier` and every tier before it. UI and extended opt-in operators require `--operators`.
    public static func operators(upTo tier: OperatorTier) -> Set<MutationOperator> {
        Set(allCases.filter { $0.domain == .logic && $0.inDefaultTiers && $0.tier <= tier })
    }

    /// What a run mutates unless told otherwise.
    public static let defaults = operators(upTo: .stable)

    /// The operators named by a comma-separated list of rule identifiers.
    public static func parse(_ list: String) throws -> Set<MutationOperator> {
        var result: Set<MutationOperator> = []
        for name in list.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !name.isEmpty {
            guard let found = MutationOperator(rawValue: name) else {
                throw LitmusFailure(
                    "unknown operator \(name); known: \(allCases.map(\.rawValue).joined(separator: ", "))"
                )
            }
            result.insert(found)
        }
        guard !result.isEmpty else { throw LitmusFailure("--operators names no operator") }
        return result
    }
}

/// A source-accurate edit. Byte offsets refer to the original UTF-8 source, never a rewritten tree.
public struct Mutation: Codable, Equatable, Sendable {
    public let id: String
    public let path: String
    public let line: Int
    public let column: Int
    public let operatorID: MutationOperator
    public let start: Int
    public let end: Int
    public let original: String
    public let replacement: String
    public let sourceFingerprint: String
    /// The enclosing declaration's path (`Type.method(_:)`, empty at file scope), part of the anchored identity.
    public var declaration: String? = nil
    /// SHA-256 of the whitespace-normalised text of the outermost enclosing body declaration (function, accessor,
    /// property...), or of the file at file scope: what `--reuse declaration` compares.
    public var declarationDigest: String? = nil

    public init(
        id: String,
        path: String,
        line: Int,
        column: Int,
        operatorID: MutationOperator,
        start: Int,
        end: Int,
        original: String,
        replacement: String,
        sourceFingerprint: String,
        declaration: String? = nil,
        declarationDigest: String? = nil
    ) {
        self.id = id
        self.path = path
        self.line = line
        self.column = column
        self.operatorID = operatorID
        self.start = start
        self.end = end
        self.original = original
        self.replacement = replacement
        self.sourceFingerprint = sourceFingerprint
        self.declaration = declaration
        self.declarationDigest = declarationDigest
    }

    /// The last line of the mutated expression.
    public var endLine: Int { line + original.count(where: { $0 == "\n" }) }
}

/// A file intentionally left out, or a file that could not be planned. Neither disappears silently.
public struct PlanNote: Codable, Equatable, Sendable {
    public let path: String
    public let reason: String
    public let isDegraded: Bool

    public init(path: String, reason: String, isDegraded: Bool = false) {
        self.path = path; self.reason = reason; self.isDegraded = isDegraded
    }
}

/// A deterministic, versioned discovery artifact. It is not evidence that tests ran.
public struct MutationPlan: Codable, Equatable, Sendable {
    public let version: Int
    public let root: String
    public let analyzedFiles: Int
    public let mutations: [Mutation]
    public let suppressed: [Mutation]
    public let notes: [PlanNote]
    /// The change the plan is limited to (`--diff`, `--diff-base`); nil for a whole-subject plan.
    public var scope: PlanScope? = nil
    /// Non-mutated sites summarised by reason (e.g. view-builder statements skipped by `remove-call`), so reports can
    /// explain omissions without inflating findings or breaking older artifacts.
    public var skipped: [String: Int]? = nil

    public init(
        root: String,
        analyzedFiles: Int,
        mutations: [Mutation],
        suppressed: [Mutation] = [],
        notes: [PlanNote] = []
    ) {
        version = 1; self.root = root; self.analyzedFiles = analyzedFiles
        self.mutations = mutations; self.suppressed = suppressed; self.notes = notes
    }
}
