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

private final class CensusVisitor: SyntaxVisitor {
    let converter: SourceLocationConverter
    let spans: [RegionSpan]
    var entries: [String: CensusEntry] = [:]
    /// Depth of result-builder declarations being walked (`var body: some View`, `@…Builder`).
    var builderDepth = 0

    init(converter: SourceLocationConverter, spans: [RegionSpan]) {
        self.converter = converter
        self.spans = spans
        super.init(viewMode: .sourceAccurate)
    }

    private func excluded(_ node: some SyntaxProtocol) -> Bool {
        let line = converter.location(for: node.positionAfterSkippingLeadingTrivia).line
        return spans.contains { $0.startLine <= line && line <= $0.endLine }
    }

    private func add(
        _ id: String,
        _ shape: SchemaShape,
        _ node: some SyntaxProtocol,
        mutants: Int = 1,
        statement: Bool = false
    ) {
        guard !excluded(node) else { return }
        var entry = entries[id] ?? CensusEntry(operatorID: id, shape: shape, sites: 0, mutants: 0, blocked: 0)
        if statement && builderDepth > 0 {
            entry.blocked += 1
        } else {
            entry.sites += 1
            entry.mutants += mutants
        }
        entries[id] = entry
    }

    // MARK: Contexts that change what an operator may do

    private static func isBuilder(_ attributes: AttributeListSyntax) -> Bool {
        attributes.contains { element in
            element.as(AttributeSyntax.self)?.attributeName.trimmedDescription.hasSuffix("Builder") == true
        }
    }
    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        let isBody = node.bindings.contains {
            $0.pattern.trimmedDescription == "body"
                && $0.typeAnnotation?.type.trimmedDescription.hasPrefix("some ") == true
        }
        if isBody || Self.isBuilder(node.attributes) { builderDepth += 1 }
        return .visitChildren
    }
    override func visitPost(_ node: VariableDeclSyntax) {
        let isBody = node.bindings.contains {
            $0.pattern.trimmedDescription == "body"
                && $0.typeAnnotation?.type.trimmedDescription.hasPrefix("some ") == true
        }
        if isBody || Self.isBuilder(node.attributes) { builderDepth -= 1 }
    }
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if Self.isBuilder(node.attributes)
            || node.signature.returnClause?.type.trimmedDescription.hasPrefix("some ") == true
        {
            builderDepth += 1
        } else if node.body != nil {
            returnDefault(node.signature.returnClause?.type, node)
        }
        return .visitChildren
    }
    override func visitPost(_ node: FunctionDeclSyntax) {
        if Self.isBuilder(node.attributes)
            || node.signature.returnClause?.type.trimmedDescription.hasPrefix("some ") == true
        {
            builderDepth -= 1
        }
    }
    override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: IfConfigClauseSyntax) -> SyntaxVisitorContinueKind {
        if let elements = node.elements { walk(elements) }
        return .skipChildren
    }
    override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: MacroExpansionDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: EnumCaseDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }

    // MARK: Return values (PIT RETURN_VALS, cargo-mutants FnValue)

    private func returnDefault(_ type: TypeSyntax?, _ node: some SyntaxProtocol) {
        guard let type else {
            add("return-early-void", .statement, node, statement: true)
            return
        }
        let text = type.trimmedDescription
        switch text {
        case "Bool": add("return-default-bool", .statement, node, mutants: 2, statement: true)
        case "Int", "UInt", "Int64", "Int32", "UInt64", "UInt32", "UInt8", "Double", "Float", "CGFloat", "TimeInterval":
            add("return-default-number", .statement, node, mutants: 2, statement: true)
        case "String": add("return-default-string", .statement, node, mutants: 2, statement: true)
        case "Void", "()": add("return-early-void", .statement, node, statement: true)
        default:
            if text.hasSuffix("?") {
                add("return-default-nil", .statement, node, statement: true)
            } else if text.hasPrefix("[") || text.hasPrefix("Set<") {
                add("return-default-empty-collection", .statement, node, statement: true)
            } else {
                add("return-default-no-default-value", .statement, node, mutants: 0, statement: true)
            }
        }
    }
    override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        if case .getter = node.accessorBlock?.accessors {
            returnDefault(node.typeAnnotation?.type, node)
        }
        return .visitChildren
    }
    override func visit(_ node: AccessorDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.accessorSpecifier.tokenKind == .keyword(.get), node.body != nil,
            let binding = node.parent?.parent?.parent?.as(PatternBindingSyntax.self)
        {
            returnDefault(binding.typeAnnotation?.type, node)
        }
        return .visitChildren
    }

    // MARK: Operators

    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        if let op = node.operator.as(BinaryOperatorExprSyntax.self) {
            switch op.operator.text {
            case "&&", "||": add("logical-replace (current)", .expression, node)
            case "==", "!=": add("relational-equality", .expression, node)
            case "<", "<=", ">", ">=": add("relational-boundary-and-negation", .expression, node, mutants: 2)
            case "+":
                let concatenation = [node.leftOperand, node.rightOperand].contains {
                    $0.is(StringLiteralExprSyntax.self)
                }
                add(concatenation ? "arithmetic-on-string-literal (unviable)" : "arithmetic-replace", .expression, node)
            case "-", "*", "/", "%": add("arithmetic-replace", .expression, node)
            case "+=", "-=", "*=", "/=", "%=": add("compound-assignment-replace", .expression, node)
            case "&", "|", "^", "<<", ">>", "&=", "|=", "^=": add("bitwise-replace", .expression, node)
            case "??": add("nil-coalescing-to-default", .expression, node)
            case "..<", "...": add("range-boundary", .expression, node)
            default: break
            }
        }
        return .visitChildren
    }
    override func visit(_ node: PrefixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        switch node.operator.text {
        case "!": add("not-removal", .expression, node)
        case "-"
        where !node.expression.is(IntegerLiteralExprSyntax.self)
            && !node.expression.is(FloatLiteralExprSyntax.self):
            add("unary-minus-removal", .expression, node)
        default: break
        }
        return .visitChildren
    }
    override func visit(_ node: BooleanLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        add("boolean-literal-flip", .expression, node)
        return .visitChildren
    }
    override func visit(_ node: IntegerLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        let value = node.literal.text
        add("integer-literal-replace", .expression, node, mutants: value == "0" || value == "1" ? 1 : 2)
        return .visitChildren
    }
    override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        guard node.segments.count > 0, node.segments.trimmedDescription != "" else { return .skipChildren }
        // Arguments of logging and assertion calls rarely change observable behaviour.
        var parent = node.parent
        while let current = parent, !current.is(FunctionCallExprSyntax.self), !current.is(CodeBlockItemSyntax.self) {
            parent = current.parent
        }
        let callee = parent?.as(FunctionCallExprSyntax.self)?.calledExpression.trimmedDescription ?? ""
        let logging =
            [
                "print", "debugPrint", "NSLog", "fatalError", "precondition", "preconditionFailure", "assert",
                "assertionFailure", "os_log",
            ].contains(callee)
            || [".debug", ".info", ".notice", ".error", ".warning", ".fault", ".trace", ".log"].contains {
                callee.hasSuffix($0)
            }
        add(logging ? "string-literal-empty (logging argument)" : "string-literal-empty", .expression, node)
        return .skipChildren
    }
    override func visit(_ node: TernaryExprSyntax) -> SyntaxVisitorContinueKind {
        add("swap-ternary (current)", .expression, node)
        return .visitChildren
    }

    // MARK: Conditions

    private func conditions(_ list: ConditionElementListSyntax) {
        for condition in list {
            switch condition.condition {
            case .expression(let expr):
                add("negate-condition (current)", .expression, expr)
                add("condition-to-constant", .expression, expr, mutants: 2)
            case .optionalBinding(let binding):
                add("optional-binding-to-nil", .expression, binding)
            default: break
            }
        }
    }
    override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
        conditions(node.conditions)
        return .visitChildren
    }
    override func visit(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind {
        conditions(node.conditions)
        return .visitChildren
    }
    override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind {
        conditions(node.conditions)
        return .visitChildren
    }

    // MARK: Statements and clauses

    override func visit(_ node: CodeBlockItemSyntax) -> SyntaxVisitorContinueKind {
        var expression = node.item.as(ExprSyntax.self)
        while let inner = expression {
            if let wrapped = inner.as(TryExprSyntax.self) {
                expression = wrapped.expression
            } else if let wrapped = inner.as(AwaitExprSyntax.self) {
                expression = wrapped.expression
            } else {
                break
            }
        }
        if let call = expression?.as(FunctionCallExprSyntax.self) {
            let name = call.calledExpression.trimmedDescription.split(separator: ".").last.map(String.init) ?? ""
            let cleanup = [
                "close", "cancel", "invalidate", "unlock", "finish", "resume", "removeObserver", "stop",
                "signal", "leave", "removeAll", "flush", "synchronize",
            ].contains(name)
            add(cleanup ? "cleanup-call-removal (fcheck)" : "void-call-removal", .statement, node, statement: true)
        }
        return .visitChildren
    }
    override func visit(_ node: DeferStmtSyntax) -> SyntaxVisitorContinueKind {
        add("defer-removal (fcheck)", .statement, node, statement: true)
        return .visitChildren
    }
    override func visit(_ node: ThrowStmtSyntax) -> SyntaxVisitorContinueKind {
        add("throw-removal", .statement, node, statement: true)
        return .visitChildren
    }
    override func visit(_ node: BreakStmtSyntax) -> SyntaxVisitorContinueKind {
        add("break-continue-swap", .statement, node, statement: true)
        return .visitChildren
    }
    override func visit(_ node: ContinueStmtSyntax) -> SyntaxVisitorContinueKind {
        add("break-continue-swap", .statement, node, statement: true)
        return .visitChildren
    }
    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        add("loop-skip (for … where)", .clause, node)
        return .visitChildren
    }
    override func visit(_ node: SwitchExprSyntax) -> SyntaxVisitorContinueKind {
        var cases: [SwitchCaseSyntax] = []
        var hasDefault = false
        for element in node.cases {
            guard case .switchCase(let item) = element else { continue }
            if case .default = item.label { hasDefault = true } else { cases.append(item) }
        }
        for item in cases {
            add(hasDefault ? "switch-case-skip (to default)" : "switch-case-skip (no default: unviable)", .clause, item)
        }
        return .visitChildren
    }
    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        let pairs: Set<String> = [
            "first", "last", "min", "max", "prefix", "suffix", "dropFirst", "dropLast", "hasPrefix", "hasSuffix",
            "uppercased", "lowercased", "popFirst", "popLast", "removeFirst", "removeLast", "startIndex", "endIndex",
        ]
        let removals: Set<String> = ["sorted", "reversed", "filter", "trimmingCharacters", "shuffled"]
        let name = node.declName.baseName.text
        if pairs.contains(name) { add("collection-method-swap", .expression, node) }
        if removals.contains(name) { add("collection-method-removal", .expression, node) }
        if name == "isEmpty" { add("isEmpty-negation", .expression, node) }
        return .visitChildren
    }
    override func visit(_ node: ClosureCaptureSyntax) -> SyntaxVisitorContinueKind {
        if let specifier = node.specifier?.specifier.text, ["weak", "unowned"].contains(specifier) {
            add("weak-capture-to-strong (arcleak)", .clause, node)
        }
        return .visitChildren
    }
    override func visit(_ node: CodeBlockItemListSyntax) -> SyntaxVisitorContinueKind {
        // Adjacent statements that both suspend: their order is a scheduling decision (modeler).
        var previousAwaits = false
        for item in node {
            let awaits = item.item.as(ExprSyntax.self).map { Self.awaits($0) } ?? false
            if awaits && previousAwaits { add("await-statement-swap (modeler)", .statement, item, statement: true) }
            previousAwaits = awaits
        }
        return .visitChildren
    }
    private static func awaits(_ expression: ExprSyntax) -> Bool {
        if expression.is(AwaitExprSyntax.self) { return true }
        if let wrapped = expression.as(TryExprSyntax.self) { return awaits(wrapped.expression) }
        return false
    }
}
