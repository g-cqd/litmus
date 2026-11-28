internal import SwiftSyntax

extension Sites {
    func pushScope(_ name: String, _ node: some SyntaxProtocol, body: Bool = false) -> SyntaxVisitorContinueKind {
        declaredTypes.append([:])
        return enter(name, node, body: body)
    }

    func popScope() {
        _ = declaredTypes.popLast()
        context.anchors.pop()
    }

    func adjustBuilderDepth(_ node: some SyntaxProtocol, by delta: Int) {
        switch BuilderContext.classify(node) {
        case .optionalViewBuilder:
            builderDepth += delta
            viewBuilderDepth += delta
        case .genericBuilder:
            builderDepth += delta
        case .none:
            break
        }
    }

    func recordParameters(_ params: FunctionParameterListSyntax) {
        guard !declaredTypes.isEmpty else { return }
        for param in params {
            let name = (param.secondName ?? param.firstName).text
            if name != "_" {
                declaredTypes[declaredTypes.count - 1][name] = normalized(param.type.trimmedDescription)
            }
        }
    }

    func enter(_ name: String, _ node: some SyntaxProtocol, body: Bool = false) -> SyntaxVisitorContinueKind {
        context.anchors.push(name, isBody: body, node)
        return .visitChildren
    }

    func addWeakCaptureMutations(_ node: ClosureExprSyntax) {
        guard let signature = node.signature,
            let captureClause = signature.capture,
            !node.statements.isEmpty,
            let firstStmt = node.statements.first
        else { return }
        let itemsText = captureClause.items.map(\.trimmedDescription).joined(separator: ", ")
        let sigAfter = sliceSource(
            from: captureClause.rightSquare.endPositionBeforeTrailingTrivia,
            to: signature.inKeyword.endPositionBeforeTrailingTrivia
        )
        let bodyPrefix = sliceSource(
            from: signature.inKeyword.endPositionBeforeTrailingTrivia,
            to: firstStmt.positionAfterSkippingLeadingTrivia
        )
        let needsExplicitReturn: Bool = {
            guard node.statements.count == 1, let expr = firstStmt.item.as(ExprSyntax.self) else { return false }
            let unwrapped = CallRemoval.unwrapTryAwait(expr)
            return !Self.chainHasOptionalChaining(unwrapped) && !Self.isNeverCall(unwrapped)
        }()
        let returnPrefix = needsExplicitReturn ? "return " : ""
        for (idx, item) in captureClause.items.enumerated() {
            guard let spec = item.specifier?.specifier.text, spec == "weak" || spec == "unowned" else { continue }
            let capturedExpr = (item.initializer?.value.trimmedDescription ?? item.name.text)
            let keepName = "_litmus_keep_\(idx)"
            let newCapture =
                "[\(itemsText), \(keepName) = \(SchemaWriter.clauseGuardPlaceholder) ? nil : (\(capturedExpr))]"
            let replacement =
                newCapture + sigAfter + bodyPrefix + "Swift.withExtendedLifetime(\(keepName)) {}; " + returnPrefix
            addSpan(
                from: captureClause.positionAfterSkippingLeadingTrivia,
                to: firstStmt.positionAfterSkippingLeadingTrivia,
                operatorID: .weakenCapture,
                replacement: replacement
            )
        }
    }

    func sliceSource(from startPos: AbsolutePosition, to endPos: AbsolutePosition) -> String {
        let s = startPos.utf8Offset, e = endPos.utf8Offset
        guard s <= e, e <= context.anchors.sourceUTF8.count else { return "" }
        return String(decoding: context.anchors.sourceUTF8[s..<e], as: UTF8.self)
    }

    func excludeInside(_ node: some SyntaxProtocol) -> SyntaxVisitorContinueKind {
        let inner = Sites(context)
        for child in node.children(viewMode: .sourceAccurate) { inner.walk(child) }
        excluded += (inner.sites + inner.excluded.map(\.site)).map {
            MutationPlanner.ExcludedSite(site: $0, reason: "inside a macro expansion; not mutated")
        }
        return .skipChildren
    }

    func visitFunctionDecl(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        adjustBuilderDepth(node, by: 1)
        let returnType = node.signature.returnClause.map { normalized($0.type.trimmedDescription) }
        returnTypes.append(returnType)
        _ = pushScope(signature(node.name.text, node.signature.parameterClause.parameters), node, body: true)
        recordParameters(node.signature.parameterClause.parameters)
        if builderDepth == 0, let body = node.body {
            if node.signature.effectSpecifiers?.throwsClause == nil,
                !CallRemoval.returnsValue(node.signature.returnClause),
                !body.statements.isEmpty,
                !CallRemoval.isAllArid(body.statements, aridCalls: context.aridCalls)
            {
                add(body.statements, operatorID: .emptyBody, replacement: "()")
            } else if let returnType,
                body.statements.count == 1,
                let onlyItem = body.statements.first,
                let expr = onlyItem.item.as(ExprSyntax.self)
            {
                // Implicit single-expression return (`func flag(_ x: Int) -> Bool { x > 0 }`).
                addReturnMutations(expr: expr, returnType: returnType)
            }
        }
        return .visitChildren
    }

    func visitInitializerDecl(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        returnTypes.append(nil)
        return enter(
            signature("init" + (node.optionalMark?.text ?? ""), node.signature.parameterClause.parameters),
            node,
            body: true
        )
    }

    func visitDeinitializerDecl(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        returnTypes.append(nil)
        return enter("deinit", node, body: true)
    }

    func visitSubscriptDecl(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        let returnType = normalized(node.returnClause.type.trimmedDescription)
        returnTypes.append(returnType)
        _ = enter(signature("subscript", node.parameterClause.parameters), node, body: true)
        if builderDepth == 0,
            case .getter(let items) = node.accessorBlock?.accessors,
            items.count == 1,
            let expr = items.first?.item.as(ExprSyntax.self)
        {
            addReturnMutations(expr: expr, returnType: returnType)
        }
        return .visitChildren
    }

    func visitClosureExpr(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        let returnType = node.signature?.returnClause.map { normalized($0.type.trimmedDescription) }
        returnTypes.append(returnType)
        // An action closure in a view body (`Button` actions, `.onChange`, `Task { }`) runs as ordinary code: the
        // logic operators apply inside it, as they do outside builders.
        if builderDepth > 0, BuilderContext.isImperativeClosure(node) {
            suspendedBuilders.append((builderDepth, viewBuilderDepth))
            (builderDepth, viewBuilderDepth) = (0, 0)
        } else {
            suspendedBuilders.append(nil)
        }
        if context.operators.contains(.weakenCapture), builderDepth == 0 {
            addWeakCaptureMutations(node)
        }
        return .visitChildren
    }

    func visitVariableDecl(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        let names = node.bindings.map { normalized($0.pattern.trimmedDescription) }.joined(separator: ",")
        adjustBuilderDepth(node, by: 1)
        return enter(names, node, body: true)
    }

    func visitPatternBinding(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        if let ident = node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
            let type = node.typeAnnotation.map({ normalized($0.type.trimmedDescription) }),
            !declaredTypes.isEmpty
        {
            declaredTypes[declaredTypes.count - 1][ident] = type
        }
        guard node.accessorBlock != nil else { return .visitChildren }
        let returnType = node.typeAnnotation.map { normalized($0.type.trimmedDescription) }
        returnTypes.append(returnType)
        if builderDepth == 0,
            let returnType,
            case .getter(let items) = node.accessorBlock?.accessors,
            items.count == 1,
            let expr = items.first?.item.as(ExprSyntax.self)
        {
            addReturnMutations(expr: expr, returnType: returnType)
        }
        return .visitChildren
    }

    func visitAccessorDecl(_ node: AccessorDeclSyntax) -> SyntaxVisitorContinueKind {
        let isGetter = node.accessorSpecifier.tokenKind == .keyword(.get)
        let getterType = isGetter ? (returnTypes.last ?? nil) : nil
        returnTypes.append(getterType)
        _ = enter(node.accessorSpecifier.text, node, body: true)
        if builderDepth == 0,
            let getterType,
            let body = node.body,
            body.statements.count == 1,
            let expr = body.statements.first?.item.as(ExprSyntax.self)
        {
            addReturnMutations(expr: expr, returnType: getterType)
        }
        return .visitChildren
    }

    func visitIfConfigClause(_ node: IfConfigClauseSyntax) -> SyntaxVisitorContinueKind {
        // The condition is compile-time syntax, not a runtime Boolean expression.
        if let elements = node.elements { walk(elements) }
        return .skipChildren
    }

    // A macro rewrites its arguments as syntax (`#Predicate`, `#expect`): a schema inside one is not plain Swift.
    func visitMacroExpansionExpr(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        excludeInside(node)
    }

    func visitPostFunctionDecl(_ node: FunctionDeclSyntax) {
        adjustBuilderDepth(node, by: -1)
        _ = returnTypes.popLast()
        popScope()
    }

    func visitPostInitializerDecl(_ node: InitializerDeclSyntax) {
        _ = returnTypes.popLast()
        context.anchors.pop()
    }

    func visitPostDeinitializerDecl(_ node: DeinitializerDeclSyntax) {
        _ = returnTypes.popLast()
        context.anchors.pop()
    }

    func visitPostSubscriptDecl(_ node: SubscriptDeclSyntax) {
        _ = returnTypes.popLast()
        context.anchors.pop()
    }

    func visitPostClosureExpr(_ node: ClosureExprSyntax) {
        _ = returnTypes.popLast()
        if let suspended = suspendedBuilders.popLast() ?? nil {
            (builderDepth, viewBuilderDepth) = (suspended.builder, suspended.viewBuilder)
        }
    }

    func visitPostVariableDecl(_ node: VariableDeclSyntax) {
        adjustBuilderDepth(node, by: -1)
        context.anchors.pop()
    }

    func visitPostPatternBinding(_ node: PatternBindingSyntax) {
        if node.accessorBlock != nil { _ = returnTypes.popLast() }
    }

    func visitPostAccessorDecl(_ node: AccessorDeclSyntax) {
        _ = returnTypes.popLast()
        context.anchors.pop()
    }
}
