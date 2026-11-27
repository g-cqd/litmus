internal import SwiftSyntax

extension Sites {
    func addCollectionTransformMutation(_ node: FunctionCallExprSyntax) {
        let calleeText = node.calledExpression.trimmedDescription
        // `Array(x.reversed())` / `Swift.Array(x.reversed())` -> `Swift.Array(x)`.
        if (calleeText == "Array" || calleeText == "Swift.Array"),
            node.arguments.count == 1,
            node.trailingClosure == nil,
            let arg = node.arguments.first,
            arg.label == nil,
            let innerCall = arg.expression.as(FunctionCallExprSyntax.self),
            innerCall.arguments.isEmpty,
            innerCall.trailingClosure == nil,
            let innerMember = innerCall.calledExpression.as(MemberAccessExprSyntax.self),
            innerMember.declName.baseName.text == "reversed",
            let base = innerMember.base,
            !Self.chainHasOptionalChaining(base)
        {
            add(node, operatorID: .replaceCollectionTransform, replacement: "Swift.Array(\(base.trimmedDescription))")
            return
        }
        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self),
            let base = member.base,
            !Self.chainHasOptionalChaining(base)
        else { return }
        let name = member.declName.baseName.text
        let loc = context.converter.location(for: member.declName.baseName.positionAfterSkippingLeadingTrivia)
        if name == "sorted", node.arguments.count <= 1 {
            if context.oracle.isArrayReturningSorted(relativePath: context.path, line: loc.line, column: loc.column)
                || isKnownSequenceReceiver(base)
            {
                add(
                    node,
                    operatorID: .replaceCollectionTransform,
                    replacement: "Swift.Array(\(base.trimmedDescription))"
                )
            }
        } else if name == "filter", (node.arguments.count + (node.trailingClosure != nil ? 1 : 0)) == 1 {
            if let shape = context.oracle.filterReturnShape(
                relativePath: context.path,
                line: loc.line,
                column: loc.column
            ) {
                let replacement =
                    shape == .array ? "Swift.Array(\(base.trimmedDescription))" : base.trimmedDescription
                add(node, operatorID: .replaceCollectionTransform, replacement: replacement)
            } else if let shape = syntacticFilterShape(base) {
                let replacement =
                    shape == .array ? "Swift.Array(\(base.trimmedDescription))" : base.trimmedDescription
                add(node, operatorID: .replaceCollectionTransform, replacement: replacement)
            }
        }
    }

    func addFirstLastSwap(_ node: MemberAccessExprSyntax, base: ExprSyntax) {
        let name = node.declName.baseName.text
        guard name == "first" || name == "last" else { return }
        let loc = context.converter.location(for: node.declName.baseName.positionAfterSkippingLeadingTrivia)
        let allowed: Bool
        if name == "last" {
            allowed =
                context.oracle.isBidirectionalLast(relativePath: context.path, line: loc.line, column: loc.column)
                || isKnownBidirectionalReceiver(base)
        } else {
            allowed = isKnownBidirectionalReceiver(base)
        }
        if allowed {
            let swapped = name == "first" ? "last" : "first"
            add(
                node,
                operatorID: .swapFirstLast,
                replacement: swappingToken(node.declName.baseName, in: node, for: swapped)
            )
        }
    }

    func lookupDeclaredType(_ expr: ExprSyntax) -> String? {
        let name: String?
        if let decl = expr.as(DeclReferenceExprSyntax.self) {
            name = decl.baseName.text
        } else if let member = expr.as(MemberAccessExprSyntax.self),
            member.base?.trimmedDescription == "self"
        {
            name = member.declName.baseName.text
        } else {
            name = nil
        }
        guard let name else { return nil }
        for scope in declaredTypes.reversed() {
            if let found = scope[name] { return found }
        }
        return nil
    }

    func isKnownBidirectionalReceiver(_ expr: ExprSyntax) -> Bool {
        if expr.is(ArrayExprSyntax.self) || expr.is(StringLiteralExprSyntax.self) { return true }
        if let call = expr.as(FunctionCallExprSyntax.self) {
            let callee = call.calledExpression.trimmedDescription
            if callee == "Array" || callee == "Swift.Array" || callee == "String" || callee == "Swift.String" {
                return true
            }
            if let m = call.calledExpression.as(MemberAccessExprSyntax.self),
                ["sorted", "map", "compactMap", "flatMap"].contains(m.declName.baseName.text)
            {
                return true
            }
        }
        guard let type = lookupDeclaredType(expr) else { return false }
        if type == "String" || type == "Substring" || type == "Swift.String" { return true }
        if type.hasPrefix("[") && type.hasSuffix("]") && !type.contains(":") { return true }
        return type.hasPrefix("Array<") || type.hasPrefix("ArraySlice<") || type.hasPrefix("ContiguousArray<")
    }

    func isKnownSequenceReceiver(_ expr: ExprSyntax) -> Bool {
        if isKnownBidirectionalReceiver(expr) { return true }
        if let call = expr.as(FunctionCallExprSyntax.self) {
            let callee = call.calledExpression.trimmedDescription
            if callee == "Set" || callee == "Swift.Set" { return true }
        }
        if let member = expr.as(MemberAccessExprSyntax.self),
            member.declName.baseName.text == "keys" || member.declName.baseName.text == "values"
        {
            return true
        }
        guard let type = lookupDeclaredType(expr) else { return false }
        return type.hasPrefix("Set<")
    }

    func syntacticFilterShape(_ expr: ExprSyntax) -> TypeOracle.FilterReturnShape? {
        if expr.is(ArrayExprSyntax.self) { return .array }
        if expr.is(StringLiteralExprSyntax.self) { return .sameReceiver }
        if let call = expr.as(FunctionCallExprSyntax.self) {
            let callee = call.calledExpression.trimmedDescription
            if callee == "Array" || callee == "Swift.Array" { return .array }
            if callee == "Set" || callee == "Swift.Set" || callee == "String" { return .sameReceiver }
            if let m = call.calledExpression.as(MemberAccessExprSyntax.self),
                ["sorted", "map", "compactMap", "flatMap"].contains(m.declName.baseName.text)
            {
                return .array
            }
        }
        guard let type = lookupDeclaredType(expr) else { return nil }
        if type.hasPrefix("[") && type.hasSuffix("]") {
            return type.contains(":") ? .sameReceiver : .array
        }
        if type.hasPrefix("Array<") || type.hasPrefix("ArraySlice<") || type.hasPrefix("ContiguousArray<") {
            return .array
        }
        if type.hasPrefix("Set<") || type.hasPrefix("Dictionary<") || type == "String" || type == "Substring" {
            return .sameReceiver
        }
        return nil
    }

    /// True if `base` propagates an unparenthesized optional chain (`a?.b` -> `.isEmpty` has type `Bool?`).
    static func chainHasOptionalChaining(_ expr: ExprSyntax) -> Bool {
        if expr.is(OptionalChainingExprSyntax.self) { return true }
        if let member = expr.as(MemberAccessExprSyntax.self), let inner = member.base {
            return chainHasOptionalChaining(inner)
        }
        if let call = expr.as(FunctionCallExprSyntax.self) {
            return chainHasOptionalChaining(call.calledExpression)
        }
        if let sub = expr.as(SubscriptCallExprSyntax.self) {
            return chainHasOptionalChaining(sub.calledExpression)
        }
        return false
    }

    func visitFunctionCallExpr(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let callee = node.calledExpression.trimmedDescription
        if CallRemoval.isAridExpressionScope(callee, aridCalls: context.aridCalls) {
            aridCallDepth += 1
            return .visitChildren
        }
        // Standard-library semantic pairs (`min`/`max`, `allSatisfy`/`contains`, `prefix`/`dropLast`,
        // `dropFirst`/`suffix`, `hasPrefix`/`hasSuffix`).
        if context.operators.contains(.replaceStdlibSemantic) {
            if let member = node.calledExpression.as(MemberAccessExprSyntax.self),
                let replacement = stdlibMemberSwap(member: member, call: node)
            {
                add(node, operatorID: .replaceStdlibSemantic, replacement: replacement)
            } else if let decl = node.calledExpression.as(DeclReferenceExprSyntax.self),
                node.arguments.count == 2,
                let swapped = Self.stdlibFreePairs[decl.baseName.text]
            {
                add(
                    node,
                    operatorID: .replaceStdlibSemantic,
                    replacement: swappingToken(decl.baseName, in: node, for: swapped)
                )
            }
        }
        if context.operators.contains(.replaceCollectionTransform) {
            addCollectionTransformMutation(node)
        }
        addSwiftUIModifierMutations(node)
        // String normalization removal (`.lowercased()`, `.uppercased()`, `.trimmingCharacters(in: ...)`).
        if context.operators.contains(.removeNormalization),
            let member = node.calledExpression.as(MemberAccessExprSyntax.self),
            let base = member.base,
            !base.is(OptionalChainingExprSyntax.self)
        {
            let name = member.declName.baseName.text
            let zeroArgNorm = (name == "lowercased" || name == "uppercased") && node.arguments.isEmpty
            let trimNorm = name == "trimmingCharacters" && node.arguments.count == 1
            if (zeroArgNorm || trimNorm) && node.trailingClosure == nil {
                add(node, operatorID: .removeNormalization, replacement: base.trimmedDescription)
            }
        }
        return .visitChildren
    }

    func visitMemberAccessExpr(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        if context.operators.contains(.swapFirstLast),
            let base = node.base,
            !Self.chainHasOptionalChaining(base),
            node.parent?.as(FunctionCallExprSyntax.self)?.calledExpression.id != Syntax(node).id
        {
            addFirstLastSwap(node, base: base)
        }
        if context.operators.contains(.negateIsEmpty),
            node.declName.baseName.text == "isEmpty",
            let base = node.base,
            !Self.chainHasOptionalChaining(base),
            node.parent?.as(FunctionCallExprSyntax.self)?.calledExpression.id != Syntax(node).id,
            !(node.parent?.as(PrefixOperatorExprSyntax.self)?.operator.text == "!"),
            !Self.isDirectCondition(ExprSyntax(node))
        {
            add(node, operatorID: .negateIsEmpty, replacement: "!(\(node.trimmedDescription))")
        }
        return .visitChildren
    }

    func visitPostFunctionCallExpr(_ node: FunctionCallExprSyntax) {
        if CallRemoval.isAridExpressionScope(node.calledExpression.trimmedDescription, aridCalls: context.aridCalls) {
            aridCallDepth -= 1
        }
    }
}
