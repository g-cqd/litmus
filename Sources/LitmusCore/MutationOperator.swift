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
    case nullifyOptionalBinding = "nullify-optional-binding"
    case negateIsEmpty = "negate-is-empty"
    case skipLoop = "skip-loop"
    case swapBreakContinue = "swap-break-continue"
    case replaceBitwise = "replace-bitwise"
    case removeUnaryMinus = "remove-unary-minus"
    case removeDefer = "remove-defer"
    case removeCleanupCall = "remove-cleanup-call"
    case weakenCapture = "weaken-capture"
    case swapAsyncOrder = "swap-async-order"
    case replaceCollectionTransform = "replace-collection-transform"
    case swapFirstLast = "swap-first-last"
    case negateDisabled = "negate-disabled"
    case removePresentation = "remove-presentation"
    case removeViewAction = "remove-view-action"
    case neutralizeViewModifier = "neutralize-view-modifier"
    case removeAccessibilityMetadata = "remove-accessibility-metadata"

    /// The kind of edit it makes, which decides how its schema is written.
    public var shape: SchemaShape {
        switch self {
        case .removeCall, .removeViewElement, .emptyBody, .emptyClosureBody, .removeDefer, .removeCleanupCall,
            .removeViewAction:
            .statement
        case .removeSwitchCase, .skipLoop, .swapBreakContinue, .weakenCapture, .swapAsyncOrder: .clause
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
            .returnBoundary, .returnConstant, .emptyBody, .emptyClosureBody, .removeSwitchCase,
            .nullifyOptionalBinding, .negateIsEmpty, .skipLoop, .swapBreakContinue, .replaceBitwise,
            .removeUnaryMinus, .removeDefer, .removeCleanupCall, .weakenCapture, .swapAsyncOrder,
            .replaceCollectionTransform, .swapFirstLast, .negateDisabled, .removePresentation, .removeViewAction,
            .neutralizeViewModifier, .removeAccessibilityMetadata:
            .experimental
        }
    }

    /// Whether this operator mutates program logic or declarative UI trees. UI operators are explicit opt-in via
    /// `--operators` so they never dilute a unit-test suite's logic mutation score.
    public var domain: OperatorDomain {
        switch self {
        case .removeViewElement, .negateDisabled, .removePresentation, .removeViewAction, .neutralizeViewModifier,
            .removeAccessibilityMetadata:
            .ui
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
            .returnConstant, .emptyBody, .emptyClosureBody, .removeSwitchCase,
            .nullifyOptionalBinding, .negateIsEmpty, .skipLoop, .swapBreakContinue, .replaceBitwise,
            .removeUnaryMinus, .removeDefer, .removeCleanupCall, .weakenCapture, .swapAsyncOrder,
            .replaceCollectionTransform, .swapFirstLast, .negateDisabled, .removePresentation, .removeViewAction,
            .neutralizeViewModifier, .removeAccessibilityMetadata:
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
        case .nullifyOptionalBinding: "force an if/guard/while optional binding to evaluate to nil"
        case .negateIsEmpty: "negate a non-optional .isEmpty check"
        case .skipLoop: "guard a for-in loop with a where clause so its body runs zero times"
        case .swapBreakContinue: "swap unlabeled break and continue inside a loop"
        case .replaceBitwise: "exchange bitwise and shift operators (& | ^ << >> &= |= ^=)"
        case .removeUnaryMinus: "remove unary negation (-x to x) on non-literal expressions"
        case .removeDefer: "skip the body of a defer block at scope exit (fault injection)"
        case .removeCleanupCall: "skip a standalone cleanup call such as cancel/invalidate/close (fault injection)"
        case .weakenCapture:
            "retain a weak or unowned closure capture strongly to test leak detection (fault injection)"
        case .swapAsyncOrder: "swap two adjacent suspension statements to test async ordering (fault injection)"
        case .replaceCollectionTransform:
            "remove collection transforms (.sorted() to Array(x), .filter(...) to x/Array(x), Array(x.reversed()) to Array(x))"
        case .swapFirstLast: "swap .first and .last on bidirectional collections (Array, ArraySlice, String)"
        case .negateDisabled: "negate a SwiftUI .disabled(...) predicate (UI domain)"
        case .removePresentation:
            "suppress SwiftUI modal/navigation presentations (.sheet, .fullScreenCover, .popover, .alert, .confirmationDialog, .navigationDestination)"
        case .removeViewAction:
            "skip a SwiftUI action: Button actions and .onAppear, .onDisappear, .task, .refreshable, .onSubmit, .onChange, .onTapGesture, .onLongPressGesture"
        case .neutralizeViewModifier:
            "make a SwiftUI view invisible or untappable (.opacity(x) to 0, .allowsHitTesting(x) to !(x))"
        case .removeAccessibilityMetadata:
            "blank literal .accessibilityLabel/.accessibilityHint and negate .accessibilityHidden (opt-in, UI domain)"
        }
    }

    /// The logic operators of `tier` and every tier before it. UI and extended opt-in operators require `--operators`.
    public static func operators(upTo tier: OperatorTier) -> Set<MutationOperator> {
        Set(allCases.filter { $0.domain == .logic && $0.inDefaultTiers && $0.tier <= tier })
    }

    /// Whether this operator benefits from compiler-resolved USRs in `TypeOracle`.
    public var usesTypeOracle: Bool {
        switch self {
        case .replaceCollectionTransform, .swapFirstLast: true
        default: false
        }
    }

    /// Whether this operator is an explicit fault-injection operator (`--fault-operators`).
    public var isFaultOperator: Bool {
        switch self {
        case .removeDefer, .removeCleanupCall, .weakenCapture, .swapAsyncOrder: true
        default: false
        }
    }

    /// The fault-injection operator bundle (`--fault-operators`).
    public static let faultOperators: Set<MutationOperator> = [
        .removeDefer, .removeCleanupCall, .weakenCapture, .swapAsyncOrder,
    ]

    /// The SwiftUI UI-domain operator bundle (`--ui-operators`); `remove-accessibility-metadata` is named explicitly.
    public static let uiOperators: Set<MutationOperator> = [
        .removeViewElement, .negateDisabled, .removePresentation, .removeViewAction, .neutralizeViewModifier,
    ]

    /// What a run mutates unless told otherwise.
    public static let defaults = operators(upTo: .stable)

    /// The operators named by a comma-separated list of rule identifiers (or `all` for every logic-domain operator).
    public static func parse(_ list: String) throws -> Set<MutationOperator> {
        var result: Set<MutationOperator> = []
        for name in list.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !name.isEmpty {
            if name == "all" {
                result.formUnion(allCases.filter { $0.domain == .logic && !$0.isFaultOperator })
                continue
            }
            if name == "fault" {
                result.formUnion(faultOperators)
                continue
            }
            if name == "ui" {
                result.formUnion(uiOperators)
                continue
            }
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
