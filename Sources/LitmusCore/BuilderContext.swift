internal import SwiftSyntax

/// Result builders collect statements as values, so a statement edit inside one changes what is built.
enum BuilderContext {
    private static let optionalViewBuilders: Set<String> = [
        "ViewBuilder", "SwiftUI.ViewBuilder",
        "ToolbarContentBuilder", "SwiftUI.ToolbarContentBuilder",
        "SceneBuilder", "SwiftUI.SceneBuilder",
        "CommandsBuilder", "SwiftUI.CommandsBuilder",
    ]
    private static let viewBodyTypes: Set<String> = [
        "some View", "some SwiftUI.View",
        "some Scene", "some SwiftUI.Scene",
        "some ToolbarContent", "some SwiftUI.ToolbarContent",
        "some Commands", "some SwiftUI.Commands",
    ]

    enum Kind {
        case none
        case genericBuilder
        case optionalViewBuilder
    }

    static func classify(_ node: some SyntaxProtocol) -> Kind {
        if let variable = node.as(VariableDeclSyntax.self) {
            if matches(variable.attributes, in: optionalViewBuilders)
                || variable.bindings.contains(where: {
                    $0.pattern.trimmedDescription == "body"
                        && $0.typeAnnotation.map { viewBodyTypes.contains(normalized($0.type.trimmedDescription)) }
                            == true
                })
            {
                return .optionalViewBuilder
            }
            if hasBuilderAttribute(variable.attributes)
                || variable.bindings.contains(where: {
                    $0.pattern.trimmedDescription == "body"
                        && $0.typeAnnotation?.type.trimmedDescription.hasPrefix("some ") == true
                })
            {
                return .genericBuilder
            }
            return .none
        }
        if let function = node.as(FunctionDeclSyntax.self) {
            if matches(function.attributes, in: optionalViewBuilders) { return .optionalViewBuilder }
            if hasBuilderAttribute(function.attributes)
                || function.signature.returnClause?.type.trimmedDescription.hasPrefix("some ") == true
            {
                return .genericBuilder
            }
        }
        return .none
    }

    /// True for a leaf view statement inside a multi-statement builder block (skipping containers with trailing
    /// view-builder closures like `Section { ... }` or `VStack { ... }` to avoid double-counting parent + children,
    /// and skipping sole statements inside non-builder closures like `Button("...") { model.calculate() }` actions).
    static func isLeafViewElement(_ call: FunctionCallExprSyntax, in node: CodeBlockItemSyntax) -> Bool {
        guard let list = node.parent?.as(CodeBlockItemListSyntax.self), let owner = list.parent else { return false }
        guard !isInsideActionClosure(node) else { return false }
        if list.count == 1 {
            // A sole statement inside an `if`, `switch`, accessor or `@ViewBuilder` function body is directly in the
            // view builder (e.g. `if let msg { Text(msg) }`). A sole statement inside an arbitrary closure (like
            // `.map { format($0) }`) may return a non-View value, so skip single-statement closures.
            let isDirectBuilderBlock: Bool
            if owner.is(AccessorBlockSyntax.self) || owner.is(SwitchCaseSyntax.self) {
                isDirectBuilderBlock = true
            } else if let block = owner.as(CodeBlockSyntax.self), let holder = block.parent {
                isDirectBuilderBlock =
                    holder.is(IfExprSyntax.self) || holder.is(AccessorDeclSyntax.self)
                    || holder.is(FunctionDeclSyntax.self)
            } else {
                isDirectBuilderBlock = false
            }
            guard isDirectBuilderBlock else { return false }
        }
        // A call whose root (unwrapping chained view modifiers like `.accessibilityElement(...)`) has a trailing
        // closure is a view container (e.g. `Section { ... }`, `VStack { ... }.padding()`); mutating its leaves avoids
        // counting one untested screen N+1 times. Interactive controls (`Button`, `Stepper`, ...) keep their imperative
        // action closure and stay leaf elements.
        let root = rootCall(of: call)
        if root.trailingClosure != nil {
            let callee = baseCalleeName(root)
            let imperativeControlNames: Set<String> = ["Button", "Link", "Stepper", "Toggle", "Slider", "Picker"]
            if !imperativeControlNames.contains(callee) { return false }
        }
        return true
    }

    /// True if `node` sits inside an imperative action closure (e.g. `Button("Go") { model.calculate() }`) rather
    /// than directly inside a view-builder block.
    private static func isInsideActionClosure(_ node: CodeBlockItemSyntax) -> Bool {
        var current: Syntax? = node.parent
        while let cur = current {
            if let closure = cur.as(ClosureExprSyntax.self), isImperativeClosure(closure) { return true }
            if cur.is(VariableDeclSyntax.self) || cur.is(FunctionDeclSyntax.self) { break }
            current = cur.parent
        }
        return false
    }

    /// Calls whose closures are actions, never view content.
    private static let actionCallees: Set<String> = [
        "Button", "onAppear", "onDisappear", "onChange", "task", "onTapGesture", "onLongPressGesture", "onSubmit",
        "refreshable", "onReceive", "onOpenURL", "onContinueUserActivity", "onDelete", "onMove", "onHover",
        "onKeyPress", "onScrollGeometryChange", "Task", "detached", "withAnimation", "withTransaction", "async",
        "asyncAfter",
    ]

    /// Closure argument labels that name an action, never view content.
    private static let actionLabels: Set<String> = [
        "action", "perform", "onDismiss", "onCompletion", "completion", "handler", "onCommit", "onEditingChanged",
    ]

    /// True for a closure that runs as code inside a view body: an argument of a known action call or labelled as
    /// an action, or one whose statements a view builder could not hold (assignments, `try`, `await`, `defer`,
    /// `guard`, `return`).
    static func isImperativeClosure(_ closure: ClosureExprSyntax) -> Bool {
        if let label = closure.parent?.as(LabeledExprSyntax.self)?.label?.text, actionLabels.contains(label) {
            return true
        }
        if let label = closure.parent?.as(MultipleTrailingClosureElementSyntax.self)?.label.text,
            actionLabels.contains(label)
        {
            return true
        }
        let owner =
            closure.parent?.as(FunctionCallExprSyntax.self)
            ?? closure.parent?.parent?.parent?.as(FunctionCallExprSyntax.self)
        if let owner, actionCallees.contains(immediateCalleeName(owner)) { return true }
        return closure.statements.contains { item in
            switch item.item {
            case .stmt(let statement):
                return statement.is(DeferStmtSyntax.self) || statement.is(GuardStmtSyntax.self)
                    || statement.is(ReturnStmtSyntax.self)
            case .decl:
                // Result builders hold local declarations (`let x = …`) since Swift 5.4.
                return false
            case .expr(let expression):
                if expression.is(TryExprSyntax.self) || expression.is(AwaitExprSyntax.self) { return true }
                guard let infix = expression.as(InfixOperatorExprSyntax.self) else { return false }
                return infix.operator.is(AssignmentExprSyntax.self)
                    || ["+=", "-=", "*=", "/=", "%="].contains(infix.operator.trimmedDescription)
            }
        }
    }

    /// Unwraps chained method/modifier calls (`VStack { ... }.padding().accessibilityElement(...)`) to the innermost
    /// `FunctionCallExprSyntax` (`VStack { ... }`).
    private static func rootCall(of call: FunctionCallExprSyntax) -> FunctionCallExprSyntax {
        var current = call
        while let member = current.calledExpression.as(MemberAccessExprSyntax.self),
            let base = member.base?.as(FunctionCallExprSyntax.self)
        {
            current = base
        }
        return current
    }

    private static func immediateCalleeName(_ call: FunctionCallExprSyntax) -> String {
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
            return member.declName.baseName.text
        }
        let text = call.calledExpression.trimmedDescription
        return text.split(separator: ".").last.map(String.init) ?? text
    }

    private static func baseCalleeName(_ call: FunctionCallExprSyntax) -> String {
        immediateCalleeName(rootCall(of: call))
    }

    private static func hasBuilderAttribute(_ attributes: AttributeListSyntax) -> Bool {
        attributes.contains {
            $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription.hasSuffix("Builder") == true
        }
    }

    private static func matches(_ attributes: AttributeListSyntax, in names: Set<String>) -> Bool {
        attributes.contains {
            guard let name = $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription else { return false }
            return names.contains(name)
        }
    }
}
