internal import SwiftSyntax

extension Sites {
    static let presentationModifiers: Set<String> = [
        "sheet", "fullScreenCover", "popover", "alert", "confirmationDialog", "navigationDestination",
    ]

    static let viewActionModifiers: Set<String> = [
        "onAppear", "onDisappear", "task", "refreshable", "onSubmit", "onChange",
    ]

    func addSwiftUIModifierMutations(_ node: FunctionCallExprSyntax) {
        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self),
            member.base != nil
        else { return }
        let name = member.declName.baseName.text
        if context.operators.contains(.negateDisabled),
            name == "disabled",
            node.arguments.count == 1,
            node.trailingClosure == nil,
            let arg = node.arguments.first,
            arg.label == nil
        {
            let expr = arg.expression
            let replacement: String
            if let prefix = expr.as(PrefixOperatorExprSyntax.self), prefix.operator.text == "!" {
                replacement = prefix.expression.trimmedDescription
            } else {
                replacement = "!(\(expr.trimmedDescription))"
            }
            add(expr, operatorID: .negateDisabled, replacement: replacement)
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
}
