internal import AemiKernel
internal import SwiftSyntax

final class Sites: SyntaxVisitor {
    let context: SiteContext

    var sites: [Mutation] = []

    var excluded: [MutationPlanner.ExcludedSite] = []

    /// Counts of sites skipped by context policy (e.g. view-builder statements when `remove-call` is active).
    var skipped: [String: Int] = [:]

    /// Depth of result-builder declarations being walked (`var body: some View`, `@…Builder`): a statement edit there
    /// would change what the builder collects.
    var builderDepth = 0

    /// Depth of SwiftUI view-builder declarations whose builder supports `buildOptional` (`if !m { ... }`).
    var viewBuilderDepth = 0

    /// Depth of attribute arguments and enum case declarations being walked: the operators added in 0.4 leave them
    /// alone (a compile-time constant there cannot read a runtime schema), the stable ones keep 0.3's behaviour.
    var constantDepth = 0

    /// Depth of arid calls (`aridCalls` + built-in logging/assertions) being walked: expression operators inside their
    /// arguments are suppressed, following Google's arid-node rule.
    var aridCallDepth = 0

    /// Stack of enclosing functions' declared return types (`nil` for Void/untyped, or normalized type string).
    var returnTypes: [String?] = []

    /// Stack of declared identifier types (`x -> "[Int]"`, `"Set<String>"`, `"String"`, ...) for conservative receiver typing.
    var declaredTypes: [[String: String]] = [[:]]

    init(_ context: SiteContext) {
        self.context = context
        super.init(viewMode: .sourceAccurate)
    }

    func add(_ expression: some SyntaxProtocol, operatorID: MutationOperator, replacement: String) {
        addSpan(
            from: expression.positionAfterSkippingLeadingTrivia,
            to: expression.endPositionBeforeTrailingTrivia,
            operatorID: operatorID,
            replacement: replacement
        )
    }

    func addSpan(
        from startPos: AbsolutePosition,
        to endPos: AbsolutePosition,
        operatorID: MutationOperator,
        replacement: String
    ) {
        guard context.operators.contains(operatorID),
            constantDepth == 0 || operatorID.tier == .stable,
            aridCallDepth == 0,
            !isExcludedByDeclaration()
        else { return }
        let start = startPos.utf8Offset
        let end = endPos.utf8Offset
        guard start < end, end <= context.anchors.sourceUTF8.count else { return }
        let original = String(decoding: context.anchors.sourceUTF8[start..<end], as: UTF8.self)
        guard !original.isEmpty, original != replacement else { return }
        let location = context.converter.location(for: startPos)
        // Anchored identity: the path, the enclosing declaration, the operator, the site's normalised text and
        // replacement, and which identical site of the declaration it is. Lines added above leave it unchanged.
        let declaration = context.anchors.path
        let anchor =
            "\(context.path)\u{0}\(declaration)\u{0}\(operatorID.rawValue)\u{0}\(normalized(original))\u{0}"
            + normalized(replacement)
        let key = anchor + "\u{0}\(context.anchors.ordinal(anchor))"
        let hash = String(XXH64.hash(Array(key.utf8)), radix: 16)
        let id = String(repeating: "0", count: 16 - hash.count) + hash
        sites.append(
            Mutation(
                id: id,
                path: context.path,
                line: location.line,
                column: location.column,
                operatorID: operatorID,
                start: start,
                end: end,
                original: original,
                replacement: replacement,
                sourceFingerprint: context.fingerprint,
                declaration: declaration,
                declarationDigest: Digest.sha256(Array(context.anchors.bodyText.utf8))
            )
        )
    }

    func isExcludedByDeclaration() -> Bool {
        guard !context.excludeDeclarations.isEmpty else { return false }
        for decl in context.anchors.stack {
            let base = decl.name.split(separator: "(").first.map(String.init) ?? decl.name
            for pattern in context.excludeDeclarations
            where CallRemoval.matchesWildcard(base, pattern: pattern)
                || CallRemoval.matchesWildcard(decl.name, pattern: pattern)
            {
                return true
            }
        }
        return false
    }

    // Declarations, for anchored identities: pushed on the way in, popped on the way out.
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { pushScope(node.name.text, node) }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { pushScope(node.name.text, node) }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { pushScope(node.name.text, node) }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind { pushScope(node.name.text, node) }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind { pushScope(node.name.text, node) }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        pushScope(normalized(node.extendedType.trimmedDescription), node)
    }

    override func visitPost(_ node: StructDeclSyntax) { popScope() }

    override func visitPost(_ node: ClassDeclSyntax) { popScope() }

    override func visitPost(_ node: EnumDeclSyntax) { popScope() }

    override func visitPost(_ node: ActorDeclSyntax) { popScope() }

    override func visitPost(_ node: ProtocolDeclSyntax) { popScope() }

    override func visitPost(_ node: ExtensionDeclSyntax) { popScope() }

    override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
        constantDepth += 1
        return .visitChildren
    }

    override func visit(_ node: EnumCaseDeclSyntax) -> SyntaxVisitorContinueKind {
        constantDepth += 1
        return .visitChildren
    }

    override func visit(_ node: MacroExpansionDeclSyntax) -> SyntaxVisitorContinueKind {
        excludeInside(node)
    }

    override func visitPost(_ node: AttributeSyntax) { constantDepth -= 1 }

    override func visitPost(_ node: EnumCaseDeclSyntax) { constantDepth -= 1 }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { visitFunctionDecl(node) }
    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind { visitInitializerDecl(node) }
    override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind { visitDeinitializerDecl(node) }
    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind { visitSubscriptDecl(node) }
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { visitClosureExpr(node) }
    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind { visitVariableDecl(node) }
    override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind { visitPatternBinding(node) }
    override func visit(_ node: AccessorDeclSyntax) -> SyntaxVisitorContinueKind { visitAccessorDecl(node) }
    override func visit(_ node: IfConfigClauseSyntax) -> SyntaxVisitorContinueKind { visitIfConfigClause(node) }
    override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind { visitMacroExpansionExpr(node) }
    override func visitPost(_ node: FunctionDeclSyntax) { visitPostFunctionDecl(node) }
    override func visitPost(_ node: InitializerDeclSyntax) { visitPostInitializerDecl(node) }
    override func visitPost(_ node: DeinitializerDeclSyntax) { visitPostDeinitializerDecl(node) }
    override func visitPost(_ node: SubscriptDeclSyntax) { visitPostSubscriptDecl(node) }
    override func visitPost(_ node: ClosureExprSyntax) { visitPostClosureExpr(node) }
    override func visitPost(_ node: VariableDeclSyntax) { visitPostVariableDecl(node) }
    override func visitPost(_ node: PatternBindingSyntax) { visitPostPatternBinding(node) }
    override func visitPost(_ node: AccessorDeclSyntax) { visitPostAccessorDecl(node) }
    override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind { visitIfExpr(node) }
    override func visit(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind { visitGuardStmt(node) }
    override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind { visitWhileStmt(node) }
    override func visit(_ node: TernaryExprSyntax) -> SyntaxVisitorContinueKind { visitTernaryExpr(node) }
    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind { visitInfixOperatorExpr(node) }
    override func visit(_ node: PrefixOperatorExprSyntax) -> SyntaxVisitorContinueKind { visitPrefixOperatorExpr(node) }
    override func visit(_ node: BooleanLiteralExprSyntax) -> SyntaxVisitorContinueKind { visitBooleanLiteralExpr(node) }
    override func visit(_ node: CodeBlockItemSyntax) -> SyntaxVisitorContinueKind { visitCodeBlockItem(node) }
    override func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind { visitReturnStmt(node) }
    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind { visitForStmt(node) }
    override func visit(_ node: BreakStmtSyntax) -> SyntaxVisitorContinueKind { visitBreakStmt(node) }
    override func visit(_ node: ContinueStmtSyntax) -> SyntaxVisitorContinueKind { visitContinueStmt(node) }
    override func visit(_ node: DeferStmtSyntax) -> SyntaxVisitorContinueKind { visitDeferStmt(node) }
    override func visit(_ node: CodeBlockItemListSyntax) -> SyntaxVisitorContinueKind { visitCodeBlockItemList(node) }
    override func visit(_ node: SwitchExprSyntax) -> SyntaxVisitorContinueKind { visitSwitchExpr(node) }
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind { visitFunctionCallExpr(node) }
    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind { visitMemberAccessExpr(node) }
    override func visitPost(_ node: FunctionCallExprSyntax) { visitPostFunctionCallExpr(node) }
    override func visit(_ node: OptionalChainingExprSyntax) -> SyntaxVisitorContinueKind {
        visitOptionalChainingExpr(node)
    }
}
