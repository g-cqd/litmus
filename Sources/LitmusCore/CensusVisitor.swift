internal import AemiRuntime
internal import Foundation
internal import ProjectModel
internal import SourceCorpus
internal import SwiftOperators
internal import SwiftParser
internal import SwiftSyntax

final class CensusVisitor: SyntaxVisitor {
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

    func excluded(_ node: some SyntaxProtocol) -> Bool {
        let line = converter.location(for: node.positionAfterSkippingLeadingTrivia).line
        return spans.contains { $0.startLine <= line && line <= $0.endLine }
    }

    func add(
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

    static func isBuilder(_ attributes: AttributeListSyntax) -> Bool {
        attributes.contains { element in
            element.as(AttributeSyntax.self)?.attributeName.trimmedDescription.hasSuffix("Builder") == true
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

    override func visit(_ node: BooleanLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        add("boolean-literal-flip", .expression, node)
        return .visitChildren
    }

    override func visit(_ node: IntegerLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        let value = node.literal.text
        add("integer-literal-replace", .expression, node, mutants: value == "0" || value == "1" ? 1 : 2)
        return .visitChildren
    }

    override func visit(_ node: TernaryExprSyntax) -> SyntaxVisitorContinueKind {
        add("swap-ternary (current)", .expression, node)
        return .visitChildren
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

    override func visit(_ node: ClosureCaptureSyntax) -> SyntaxVisitorContinueKind {
        if let specifier = node.specifier?.specifier.text, ["weak", "unowned"].contains(specifier) {
            add("weak-capture-to-strong (arcleak)", .clause, node)
        }
        return .visitChildren
    }

    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind { visitInfixOperatorExpr(node) }
    override func visit(_ node: PrefixOperatorExprSyntax) -> SyntaxVisitorContinueKind { visitPrefixOperatorExpr(node) }
    override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind { visitStringLiteralExpr(node) }
    override func visit(_ node: CodeBlockItemSyntax) -> SyntaxVisitorContinueKind { visitCodeBlockItem(node) }
    override func visit(_ node: SwitchExprSyntax) -> SyntaxVisitorContinueKind { visitSwitchExpr(node) }
    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind { visitMemberAccessExpr(node) }
    override func visit(_ node: CodeBlockItemListSyntax) -> SyntaxVisitorContinueKind { visitCodeBlockItemList(node) }
    override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind { visitPatternBinding(node) }
    override func visit(_ node: AccessorDeclSyntax) -> SyntaxVisitorContinueKind { visitAccessorDecl(node) }
    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind { visitVariableDecl(node) }
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { visitFunctionDecl(node) }
    override func visitPost(_ node: VariableDeclSyntax) { visitPostVariableDecl(node) }
    override func visitPost(_ node: FunctionDeclSyntax) { visitPostFunctionDecl(node) }
}
