internal import SwiftOperators
internal import SwiftSyntax

extension Sites {
    func conditions(_ list: ConditionElementListSyntax) {
        for condition in list {
            switch condition.condition {
            case .expression(let expr):
                add(expr, operatorID: .negateCondition, replacement: "!(\(expr.trimmedDescription))")
            case .optionalBinding(let binding) where context.operators.contains(.nullifyOptionalBinding):
                if let initClause = binding.initializer {
                    let inner = CallRemoval.unwrapTryAwait(initClause.value)
                    if inner.trimmedDescription != "nil", !Self.isNeverCall(inner) {
                        add(inner, operatorID: .nullifyOptionalBinding, replacement: "nil")
                    }
                } else if binding.bindingSpecifier.tokenKind == .keyword(.let)
                    || binding.bindingSpecifier.tokenKind == .keyword(.var),
                    let ident = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
                {
                    // Shorthand `if let x` / `guard let self`: expand to an explicit conditional binding via clause guard.
                    let replacement =
                        "\(binding.trimmedDescription) = \(SchemaWriter.clauseGuardPlaceholder) ? \(ident) : nil"
                    add(binding, operatorID: .nullifyOptionalBinding, replacement: replacement)
                }
            default:
                break
            }
        }
    }

    /// Boundary shifts and negations: `<` becomes `<=` (boundary) and `>=` (negation), and so on; equality flips.
    static let relational: [String: [String]] = [
        "<": ["<=", ">="], "<=": ["<", ">"], ">": [">=", "<="], ">=": [">", "<"], "==": ["!="], "!=": ["=="],
    ]

    static let arithmetic: [String: String] = ["+": "-", "-": "+", "*": "/", "/": "*", "%": "*"]

    static let compoundAssignment: [String: String] = ["+=": "-=", "-=": "+=", "*=": "/=", "/=": "*=", "%=": "*="]

    static let bitwise: [String: String] = [
        "&": "|", "|": "&", "^": "&", "<<": ">>", ">>": "<<", "&=": "|=", "|=": "&=", "^=": "&=",
    ]

    static func isStringLiteral(_ expression: ExprSyntax) -> Bool {
        expression.is(StringLiteralExprSyntax.self)
    }

    static func isCollectionOrStringLiteral(_ expression: ExprSyntax) -> Bool {
        expression.is(StringLiteralExprSyntax.self) || expression.is(ArrayExprSyntax.self)
    }

    /// True when mutating `left <symbol> right` (`/` or `%` -> `*`, `-` -> `+`, `+` -> `-`) produces an expression on
    /// `.max` or `.min` with a literal operand that Swift's constant folder rejects at compile time as an integer
    /// overflow (for example `Int.max / 2` -> `Int.max * 2`).
    static func isGuaranteedConstantOverflow(symbol: String, left: ExprSyntax, right: ExprSyntax) -> Bool {
        func boundKind(_ expr: ExprSyntax) -> String? {
            guard let member = expr.as(MemberAccessExprSyntax.self) else { return nil }
            let name = member.declName.baseName.text
            guard name == "max" || name == "min" else { return nil }
            let base = member.base?.trimmedDescription ?? ""
            return base.isEmpty || numericReturnTypes.contains(base) ? name : nil
        }
        func positiveIntLiteral(_ expr: ExprSyntax, atLeast minimum: Int) -> Bool {
            guard let lit = expr.as(IntegerLiteralExprSyntax.self),
                let val = Int(lit.literal.text.replacingOccurrences(of: "_", with: ""))
            else { return false }
            return val >= minimum
        }
        switch symbol {
        case "/", "%":
            // Replacing `/` or `%` with `*`: `Int.max * k` or `k * Int.max` (k >= 2), and `Int.min * k` (k >= 2).
            if boundKind(left) != nil && positiveIntLiteral(right, atLeast: 2) { return true }
            if boundKind(right) != nil && positiveIntLiteral(left, atLeast: 2) { return true }
            return false
        case "-":
            // Replacing `-` with `+`: `Int.max + k` (k >= 1).
            return boundKind(left) == "max" && positiveIntLiteral(right, atLeast: 1)
        case "+":
            // Replacing `+` with `-`: `Int.min - k` (k >= 1).
            return boundKind(left) == "min" && positiveIntLiteral(right, atLeast: 1)
        default:
            return false
        }
    }

    static func isNeverCall(_ expression: ExprSyntax) -> Bool {
        guard let call = expression.as(FunctionCallExprSyntax.self) else { return false }
        let last = call.calledExpression.trimmedDescription.split(separator: ".").last.map(String.init) ?? ""
        return ["fatalError", "preconditionFailure", "assertionFailure", "swift_unreachable"].contains(last)
    }

    /// True when `node` is the whole expression of an `if`/`guard`/`while` condition or ternary predicate, where
    /// `negate-condition` or `swap-ternary` already emits the identical mutation.
    static func isDirectCondition(_ node: ExprSyntax) -> Bool {
        guard let parent = node.parent else { return false }
        if parent.is(ConditionElementSyntax.self) { return true }
        if let ternary = parent.as(TernaryExprSyntax.self), ternary.condition.id == node.id { return true }
        return false
    }

    /// The text of `node` with only its operator token replaced, so comments and layout around it survive.
    func swapping(_ op: BinaryOperatorExprSyntax, in node: InfixOperatorExprSyntax, for replacement: String)
        -> String
    {
        let text = Array(node.trimmedDescription.utf8)
        let base = node.positionAfterSkippingLeadingTrivia.utf8Offset
        let start = op.operator.positionAfterSkippingLeadingTrivia.utf8Offset - base
        let end = op.operator.endPositionBeforeTrailingTrivia.utf8Offset - base
        guard start >= 0, end <= text.count, start < end else { return node.trimmedDescription }
        return String(decoding: text[..<start] + Array(replacement.utf8) + text[end...], as: UTF8.self)
    }

    func visitIfExpr(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
        conditions(node.conditions)
        return .visitChildren
    }

    func visitGuardStmt(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind {
        conditions(node.conditions)
        return .visitChildren
    }

    func visitWhileStmt(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind {
        conditions(node.conditions)
        return .visitChildren
    }

    func visitTernaryExpr(_ node: TernaryExprSyntax) -> SyntaxVisitorContinueKind {
        add(node.condition, operatorID: .swapTernary, replacement: "!(\(node.condition.trimmedDescription))")
        return .visitChildren
    }

    func visitInfixOperatorExpr(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        guard let op = node.operator.as(BinaryOperatorExprSyntax.self) else { return .visitChildren }
        let symbol = op.operator.text
        if ["&&", "||"].contains(symbol) {
            let other = symbol == "&&" ? "||" : "&&"
            // Operands keep their folded grouping: `a || b || c` is `(a || b) || c`, whose outer mutant is
            // `(a || b) && (c)`, not the regrouped text `a || b && c`.
            add(
                node,
                operatorID: .replaceLogical,
                replacement:
                    "(\(node.leftOperand.trimmedDescription)) \(other) (\(node.rightOperand.trimmedDescription))"
            )
        } else if let replacements = Self.relational[symbol] {
            for replacement in replacements {
                add(node, operatorID: .replaceRelational, replacement: swapping(op, in: node, for: replacement))
            }
        } else if let replacement = Self.arithmetic[symbol],
            !Self.isStringLiteral(node.leftOperand), !Self.isStringLiteral(node.rightOperand),
            !Self.isGuaranteedConstantOverflow(symbol: symbol, left: node.leftOperand, right: node.rightOperand)
        {
            // `"a" + b` is concatenation and `Int.max * 2` is a constant-folded overflow: neither compiles, so
            // skipping them avoids paying a failed schema build just to classify an impossible edit.
            add(node, operatorID: .replaceArithmetic, replacement: swapping(op, in: node, for: replacement))
        } else if let replacement = Self.compoundAssignment[symbol],
            !(symbol == "+=" && Self.isCollectionOrStringLiteral(node.rightOperand))
        {
            add(node, operatorID: .replaceArithmetic, replacement: swapping(op, in: node, for: replacement))
        } else if (symbol == "..<" || symbol == "..."),
            !node.hasAncestor(SwitchCaseItemSyntax.self),
            !Self.isStringLiteral(node.leftOperand), !Self.isStringLiteral(node.rightOperand)
        {
            // Preserve Range vs ClosedRange type by shifting the upper bound rather than swapping `..<` and `...`
            // (a ternary schema requires identical branch types).
            let shifted =
                symbol == "..<"
                ? "((\(node.rightOperand.trimmedDescription)) + 1)" : "((\(node.rightOperand.trimmedDescription)) - 1)"
            let replacement = "\(node.leftOperand.trimmedDescription)\(symbol)\(shifted)"
            add(node, operatorID: .replaceRange, replacement: replacement)
        } else if symbol == "??", !Self.isNeverCall(node.rightOperand) {
            // `a ?? fatalError()` has a `Never` fallback that cannot balance the ternary schema's branches.
            add(node, operatorID: .replaceNilCoalescing, replacement: node.rightOperand.trimmedDescription)
        } else if let replacement = Self.bitwise[symbol] {
            add(node, operatorID: .replaceBitwise, replacement: swapping(op, in: node, for: replacement))
        }
        return .visitChildren
    }

    func visitPrefixOperatorExpr(_ node: PrefixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        if node.operator.text == "!", !Self.isDirectCondition(ExprSyntax(node)) {
            add(node, operatorID: .removeNegation, replacement: node.expression.trimmedDescription)
        } else if node.operator.text == "-",
            !node.expression.is(IntegerLiteralExprSyntax.self),
            !node.expression.is(FloatLiteralExprSyntax.self),
            !node.hasAncestor(SwitchCaseItemSyntax.self)
        {
            add(node, operatorID: .removeUnaryMinus, replacement: node.expression.trimmedDescription)
        }
        return .visitChildren
    }

    func visitBooleanLiteralExpr(_ node: BooleanLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        // A literal in a `case` pattern is matched, not evaluated: flipping it breaks exhaustiveness.
        guard !node.hasAncestor(SwitchCaseItemSyntax.self) else { return .visitChildren }
        add(node, operatorID: .flipBoolean, replacement: node.literal.text == "true" ? "false" : "true")
        return .visitChildren
    }
}
