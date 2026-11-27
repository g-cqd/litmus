internal import SwiftSyntax

extension Sites {
    static func isNumericOrBoolLiteral(_ expr: ExprSyntax) -> Bool {
        if expr.is(IntegerLiteralExprSyntax.self) || expr.is(FloatLiteralExprSyntax.self)
            || expr.is(BooleanLiteralExprSyntax.self)
        {
            return true
        }
        if let prefix = expr.as(PrefixOperatorExprSyntax.self), prefix.operator.text == "-" {
            return prefix.expression.is(IntegerLiteralExprSyntax.self)
                || prefix.expression.is(FloatLiteralExprSyntax.self)
        }
        return false
    }

    func addReturnMutations(expr: ExprSyntax, returnType: String) {
        let trimmed = expr.trimmedDescription
        if context.operators.contains(.returnBoundary) {
            // Skip plain numeric literals (`return 0` -> `(0) + 1`), which duplicate `return-constant` (`return 1`),
            // and skip binary relational expressions (`return a <= b`), which `replace-relational` already covers.
            if Self.numericReturnTypes.contains(returnType), !Self.isNumericOrBoolLiteral(expr) {
                add(expr, operatorID: .returnBoundary, replacement: "(\(trimmed)) + 1")
            } else if returnType == "String" || returnType == "Swift.String", trimmed != "\"\"" {
                add(expr, operatorID: .returnBoundary, replacement: "\"\"")
            } else if returnType.hasPrefix("[") && returnType.hasSuffix("]") && !returnType.contains(":"),
                trimmed != "[]"
            {
                add(expr, operatorID: .returnBoundary, replacement: "[]")
            }
        }
        if context.operators.contains(.returnConstant) {
            if returnType == "Bool" || returnType == "Swift.Bool" {
                let isRelational =
                    expr.as(InfixOperatorExprSyntax.self)
                    .flatMap { $0.operator.as(BinaryOperatorExprSyntax.self)?.operator.trimmedDescription }
                    .map { Self.relational[$0] != nil } == true
                if trimmed != "true" && trimmed != "false" && !isRelational {
                    add(expr, operatorID: .returnConstant, replacement: "true")
                    add(expr, operatorID: .returnConstant, replacement: "false")
                }
            } else if returnType.hasSuffix("?"), trimmed != "nil" {
                add(expr, operatorID: .returnConstant, replacement: "nil")
            } else if Self.numericReturnTypes.contains(returnType) {
                add(expr, operatorID: .returnConstant, replacement: trimmed == "0" ? "1" : "0")
            }
        }
    }

    func addLoopJumpSwap(_ node: some SyntaxProtocol, original: String, swapped: String) {
        guard context.operators.contains(.swapBreakContinue),
            builderDepth == 0,
            node.parent?.is(CodeBlockItemSyntax.self) == true
        else { return }
        add(
            node,
            operatorID: .swapBreakContinue,
            replacement: "if \(SchemaWriter.clauseGuardPlaceholder) { \(original) } else { \(swapped) }"
        )
    }

    /// True if `node` is enclosed by a `for`, `while` or `repeat` loop without crossing a function/closure/accessor.
    static func isInsideLoopInCurrentFunction(_ node: some SyntaxProtocol) -> Bool {
        var current = node.parent
        while let cur = current {
            if cur.is(ForStmtSyntax.self) || cur.is(WhileStmtSyntax.self) || cur.is(RepeatStmtSyntax.self) {
                return true
            }
            if cur.is(FunctionDeclSyntax.self) || cur.is(ClosureExprSyntax.self) || cur.is(AccessorDeclSyntax.self)
                || cur.is(InitializerDeclSyntax.self) || cur.is(SubscriptDeclSyntax.self)
            {
                return false
            }
            current = cur.parent
        }
        return false
    }

    /// True if `expr` is `[try] await call(...)` (not an assignment or declaration, so reordering preserves bindings).
    static func isSuspensionCallStatement(_ expr: ExprSyntax) -> Bool {
        var sawAwait = false
        var current = expr
        while true {
            if let t = current.as(TryExprSyntax.self) {
                current = t.expression
            } else if let a = current.as(AwaitExprSyntax.self) {
                sawAwait = true
                current = a.expression
            } else {
                break
            }
        }
        return sawAwait && current.is(FunctionCallExprSyntax.self)
    }

    func visitCodeBlockItem(_ node: CodeBlockItemSyntax) -> SyntaxVisitorContinueKind {
        guard let expression = node.item.as(ExprSyntax.self),
            let call = CallRemoval.unwrapTryAwait(expression).as(FunctionCallExprSyntax.self)
        else { return .visitChildren }
        if builderDepth == 0 {
            let callee = call.calledExpression.trimmedDescription
            if !CallRemoval.isArid(callee, aridCalls: context.aridCalls),
                !CallRemoval.isImplicitReturn(node)
            {
                if context.operators.contains(.removeCall) {
                    add(expression, operatorID: .removeCall, replacement: "()")
                } else if context.operators.contains(.removeCleanupCall), CallRemoval.isCleanupCall(callee) {
                    add(expression, operatorID: .removeCleanupCall, replacement: "()")
                }
                if context.operators.contains(.emptyClosureBody),
                    let closure = call.trailingClosure,
                    call.additionalTrailingClosures.isEmpty,
                    !closure.statements.isEmpty,
                    !CallRemoval.isLockOrSyncWrapper(callee),
                    !CallRemoval.isAllArid(closure.statements, aridCalls: context.aridCalls)
                {
                    add(closure.statements, operatorID: .emptyClosureBody, replacement: "()")
                }
            }
        } else if viewBuilderDepth > 0, BuilderContext.isLeafViewElement(call, in: node) {
            if context.operators.contains(.removeViewElement) {
                add(expression, operatorID: .removeViewElement, replacement: "()")
            } else if context.operators.contains(.removeCall) {
                skipped[MutationPlanner.skippedViewBuilderReason, default: 0] += 1
            }
        }
        return .visitChildren
    }

    func visitReturnStmt(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind {
        guard builderDepth == 0,
            let expr = node.expression,
            let returnType = returnTypes.last ?? nil
        else { return .visitChildren }
        addReturnMutations(expr: expr, returnType: returnType)
        return .visitChildren
    }

    func visitForStmt(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        if context.operators.contains(.skipLoop) {
            if let whereClause = node.whereClause {
                let cond = whereClause.condition.trimmedDescription
                add(
                    whereClause,
                    operatorID: .skipLoop,
                    replacement: "where (\(cond)) && \(SchemaWriter.clauseGuardPlaceholder)"
                )
            } else {
                add(
                    node.sequence,
                    operatorID: .skipLoop,
                    replacement: "\(node.sequence.trimmedDescription) where \(SchemaWriter.clauseGuardPlaceholder)"
                )
            }
        }
        return .visitChildren
    }

    func visitBreakStmt(_ node: BreakStmtSyntax) -> SyntaxVisitorContinueKind {
        if node.label == nil, Self.isInsideLoopInCurrentFunction(node) {
            addLoopJumpSwap(node, original: "break", swapped: "continue")
        }
        return .visitChildren
    }

    func visitContinueStmt(_ node: ContinueStmtSyntax) -> SyntaxVisitorContinueKind {
        if node.label == nil { addLoopJumpSwap(node, original: "continue", swapped: "break") }
        return .visitChildren
    }

    func visitDeferStmt(_ node: DeferStmtSyntax) -> SyntaxVisitorContinueKind {
        if context.operators.contains(.removeDefer),
            builderDepth == 0,
            !node.body.statements.isEmpty,
            !CallRemoval.containsLockUnlock(node.body.statements),
            !CallRemoval.isAllArid(node.body.statements, aridCalls: context.aridCalls)
        {
            // Mutate the body inside `defer { ... }` rather than wrapping `defer` itself in `if !m` (which would
            // run the defer at the end of the `if` scope instead of the enclosing scope when inactive).
            add(node.body.statements, operatorID: .removeDefer, replacement: "()")
        }
        return .visitChildren
    }

    func visitCodeBlockItemList(_ node: CodeBlockItemListSyntax) -> SyntaxVisitorContinueKind {
        if context.operators.contains(.swapAsyncOrder), builderDepth == 0 {
            let items = Array(node)
            if items.count >= 2 {
                for index in 0..<(items.count - 1) {
                    let first = items[index], second = items[index + 1]
                    guard let e1 = first.item.as(ExprSyntax.self),
                        let e2 = second.item.as(ExprSyntax.self),
                        Self.isSuspensionCallStatement(e1),
                        Self.isSuspensionCallStatement(e2),
                        !CallRemoval.isImplicitReturn(second)
                    else { continue }
                    let s1 = first.trimmedDescription, s2 = second.trimmedDescription
                    let replacement =
                        "if \(SchemaWriter.clauseGuardPlaceholder) { \(s1); \(s2) } else { \(s2); \(s1) }"
                    addSpan(
                        from: first.positionAfterSkippingLeadingTrivia,
                        to: second.endPositionBeforeTrailingTrivia,
                        operatorID: .swapAsyncOrder,
                        replacement: replacement
                    )
                }
            }
        }
        return .visitChildren
    }

    func visitSwitchExpr(_ node: SwitchExprSyntax) -> SyntaxVisitorContinueKind {
        guard context.operators.contains(.removeSwitchCase) else { return .visitChildren }
        var nonDefaultCases: [SwitchCaseSyntax] = []
        var hasDefault = false
        for element in node.cases {
            guard case .switchCase(let switchCase) = element else { continue }
            if case .default = switchCase.label {
                hasDefault = true
            } else if case .case(let label) = switchCase.label, !switchCase.statements.isEmpty {
                let fallsThrough =
                    switchCase.statements.count == 1
                    && switchCase.statements.first?.item.is(FallThroughStmtSyntax.self) == true
                let hasBindings = label.caseItems.contains {
                    $0.pattern.trimmedDescription.contains("let ")
                        || $0.pattern.trimmedDescription.contains("var ")
                }
                if !fallsThrough && !hasBindings {
                    nonDefaultCases.append(switchCase)
                }
            }
        }
        guard hasDefault else { return .visitChildren }
        for switchCase in nonDefaultCases {
            guard case .case(let label) = switchCase.label else { continue }
            var items: [String] = []
            for item in label.caseItems {
                let pattern = item.pattern.trimmedDescription
                if let whereClause = item.whereClause {
                    let cond = whereClause.condition.trimmedDescription
                    items.append("\(pattern) where (\(cond)) && \(SchemaWriter.clauseGuardPlaceholder)")
                } else {
                    items.append("\(pattern) where \(SchemaWriter.clauseGuardPlaceholder)")
                }
            }
            let replacement = "case " + items.joined(separator: ", ") + ":"
            add(label, operatorID: .removeSwitchCase, replacement: replacement)
        }
        return .visitChildren
    }
}
