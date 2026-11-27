internal import SwiftSyntax

extension Sites {
    static let stdlibMemberPairs: [String: String] = [
        "min": "max", "max": "min",
        "prefix": "dropLast", "dropLast": "prefix",
        "dropFirst": "suffix", "suffix": "dropFirst",
        "hasPrefix": "hasSuffix", "hasSuffix": "hasPrefix",
    ]

    static let stdlibFreePairs: [String: String] = ["min": "max", "max": "min"]

    static let numericReturnTypes: Set<String> = [
        "Int", "UInt", "Int64", "Int32", "Int16", "Int8", "UInt64", "UInt32", "UInt16", "UInt8",
        "Double", "Float", "CGFloat", "TimeInterval",
    ]

    func stdlibMemberSwap(member: MemberAccessExprSyntax, call: FunctionCallExprSyntax) -> String? {
        let name = member.declName.baseName.text
        if name == "contains" {
            if call.arguments.isEmpty, call.trailingClosure != nil {
                return swappingToken(member.declName.baseName, in: call, for: "allSatisfy")
            }
            if call.arguments.count == 1, let first = call.arguments.first, first.label?.text == "where",
                call.trailingClosure == nil, let base = member.base
            {
                return "\(base.trimmedDescription).allSatisfy(\(first.expression.trimmedDescription))"
            }
            return nil
        }
        if name == "allSatisfy" {
            if call.arguments.isEmpty, call.trailingClosure != nil {
                return swappingToken(member.declName.baseName, in: call, for: "contains")
            }
            if call.arguments.count == 1, let first = call.arguments.first, first.label == nil,
                call.trailingClosure == nil, let base = member.base
            {
                return "\(base.trimmedDescription).contains(where: \(first.expression.trimmedDescription))"
            }
            return nil
        }
        guard let swapped = Self.stdlibMemberPairs[name] else { return nil }
        return swappingToken(member.declName.baseName, in: call, for: swapped)
    }

    func swappingToken(_ token: TokenSyntax, in node: some SyntaxProtocol, for replacement: String) -> String {
        let text = Array(node.trimmedDescription.utf8)
        let base = node.positionAfterSkippingLeadingTrivia.utf8Offset
        let start = token.positionAfterSkippingLeadingTrivia.utf8Offset - base
        let end = token.endPositionBeforeTrailingTrivia.utf8Offset - base
        guard start >= 0, end <= text.count, start < end else { return node.trimmedDescription }
        return String(decoding: text[..<start] + Array(replacement.utf8) + text[end...], as: UTF8.self)
    }

    /// Climbs the postfix member/call/subscript chain whose value becomes optional because of `node` (`box?.count` or
    /// `box?.items[0].name`), so `(m ? (box!.count) : (box?.count))` is a valid standalone expression.
    static func enclosingOptionalChainTarget(_ node: OptionalChainingExprSyntax) -> Syntax {
        var current = Syntax(node)
        while let parent = current.parent {
            if let member = parent.as(MemberAccessExprSyntax.self), member.base?.id == current.id {
                current = parent
            } else if let call = parent.as(FunctionCallExprSyntax.self), call.calledExpression.id == current.id {
                current = parent
            } else if let sub = parent.as(SubscriptCallExprSyntax.self), sub.calledExpression.id == current.id {
                current = parent
            } else if let opt = parent.as(OptionalChainingExprSyntax.self), opt.expression.id == current.id {
                current = parent
            } else {
                break
            }
        }
        return current
    }

    static func isLeftSideOfAssignment(_ node: OptionalChainingExprSyntax) -> Bool {
        let target = enclosingOptionalChainTarget(node)
        guard let infix = target.parent?.as(InfixOperatorExprSyntax.self) else { return false }
        let op = infix.operator.trimmedDescription
        let isAssign = op == "=" || compoundAssignment[op] != nil
        return isAssign && infix.leftOperand.id == target.id
    }

    func visitOptionalChainingExpr(_ node: OptionalChainingExprSyntax) -> SyntaxVisitorContinueKind {
        if context.operators.contains(.replaceOptionalChain),
            !Self.isLeftSideOfAssignment(node)
        {
            let target = Self.enclosingOptionalChainTarget(node)
            if target.id != Syntax(node).id {
                add(
                    target,
                    operatorID: .replaceOptionalChain,
                    replacement: swappingToken(node.questionMark, in: target, for: "!")
                )
            }
        }
        return .visitChildren
    }
}
