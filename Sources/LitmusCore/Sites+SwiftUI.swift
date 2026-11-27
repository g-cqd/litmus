internal import SwiftSyntax

extension Sites {
    static let presentationModifiers: Set<String> = [
        "sheet", "fullScreenCover", "popover", "alert", "confirmationDialog", "navigationDestination",
    ]

    static let viewActionModifiers: Set<String> = [
        "onAppear", "onDisappear", "task", "refreshable", "onSubmit", "onChange", "onTapGesture",
        "onLongPressGesture",
    ]

    /// Accessibility modifiers whose string-literal argument `remove-accessibility-metadata` blanks.
    static let accessibilityTextModifiers: Set<String> = ["accessibilityLabel", "accessibilityHint"]

    func addSwiftUIModifierMutations(_ node: FunctionCallExprSyntax) {
        addButtonActionMutation(node)
        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self),
            member.base != nil
        else { return }
        let name = member.declName.baseName.text
        addViewModifierArgumentMutations(node, name: name)
        if context.operators.contains(.negateDisabled),
            name == "disabled",
            node.arguments.count == 1,
            node.trailingClosure == nil,
            let arg = node.arguments.first,
            arg.label == nil
        {
            add(arg.expression, operatorID: .negateDisabled, replacement: Self.negated(arg.expression))
        }
        if context.operators.contains(.removePresentation), Self.presentationModifiers.contains(name) {
            if let arg = node.arguments.first(where: { $0.label?.text == "isPresented" }) {
                if arg.expression.trimmedDescription != ".constant(false)" {
                    add(arg.expression, operatorID: .removePresentation, replacement: ".constant(false)")
                }
            } else if let arg = node.arguments.first(where: { $0.label?.text == "item" }) {
                if arg.expression.trimmedDescription != ".constant(nil)" {
                    add(arg.expression, operatorID: .removePresentation, replacement: ".constant(nil)")
                }
            } else if name == "navigationDestination",
                node.arguments.contains(where: { $0.label?.text == "for" }),
                let closure = node.trailingClosure,
                node.additionalTrailingClosures.isEmpty,
                !closure.statements.isEmpty
            {
                let bodyText = closure.statements.trimmedDescription
                add(
                    closure.statements,
                    operatorID: .removePresentation,
                    replacement: "if \(SchemaWriter.clauseGuardPlaceholder) { \(bodyText) }"
                )
            }
        }
        if context.operators.contains(.removeViewAction),
            Self.viewActionModifiers.contains(name),
            let closure = node.trailingClosure,
            node.additionalTrailingClosures.isEmpty,
            !closure.statements.isEmpty,
            !CallRemoval.isAllArid(closure.statements, aridCalls: context.aridCalls)
        {
            add(closure.statements, operatorID: .removeViewAction, replacement: "()")
        }
    }

    /// `remove-view-action` on a `Button`'s action: the `action:` closure, or the trailing closure when it is the
    /// action (after an unlabeled title, or before a `label:` closure). After `action:` or `intent:` it is the label.
    func addButtonActionMutation(_ node: FunctionCallExprSyntax) {
        guard context.operators.contains(.removeViewAction),
            node.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "Button"
        else { return }
        let closure: ClosureExprSyntax?
        if let action = node.arguments.first(where: { $0.label?.text == "action" }) {
            closure = action.expression.as(ClosureExprSyntax.self)
        } else if let trailing = node.trailingClosure,
            node.additionalTrailingClosures.isEmpty
                ? (node.arguments.first.map({ $0.label == nil }) ?? false)
                : node.additionalTrailingClosures.first?.label.text == "label"
        {
            closure = trailing
        } else {
            closure = nil
        }
        guard let closure, !closure.statements.isEmpty,
            !CallRemoval.isAllArid(closure.statements, aridCalls: context.aridCalls)
        else { return }
        add(closure.statements, operatorID: .removeViewAction, replacement: "()")
    }

    /// Type-preserving argument mutations: the modifier stays, so the view's static type does not change.
    func addViewModifierArgumentMutations(_ node: FunctionCallExprSyntax, name: String) {
        guard node.arguments.count == 1, node.trailingClosure == nil, let arg = node.arguments.first,
            arg.label == nil
        else { return }
        let expr = arg.expression
        let text = expr.trimmedDescription
        if name == "opacity", text != "0", text != "0.0" {
            add(expr, operatorID: .neutralizeViewModifier, replacement: "0")
        } else if name == "allowsHitTesting" {
            add(expr, operatorID: .neutralizeViewModifier, replacement: Self.negated(expr))
        } else if name == "accessibilityHidden" {
            add(expr, operatorID: .removeAccessibilityMetadata, replacement: Self.negated(expr))
        } else if Self.accessibilityTextModifiers.contains(name), let literal = expr.as(StringLiteralExprSyntax.self),
            literal.segments.trimmedDescription != ""
        {
            add(expr, operatorID: .removeAccessibilityMetadata, replacement: "\"\"")
        }
    }

    /// `!x` for `x`, and `x` for `!x`.
    static func negated(_ expr: ExprSyntax) -> String {
        if let prefix = expr.as(PrefixOperatorExprSyntax.self), prefix.operator.text == "!" {
            return prefix.expression.trimmedDescription
        }
        return "!(\(expr.trimmedDescription))"
    }
}
