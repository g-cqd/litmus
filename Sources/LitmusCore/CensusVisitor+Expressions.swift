internal import AemiRuntime
internal import Foundation
internal import ProjectModel
internal import SourceCorpus
internal import SwiftOperators
internal import SwiftParser
internal import SwiftSyntax

extension CensusVisitor {
    func returnDefault(_ type: TypeSyntax?, _ node: some SyntaxProtocol) {
        guard let type else {
            add("return-early-void", .statement, node, statement: true)
            return
        }
        let text = type.trimmedDescription
        switch text {
        case "Bool": add("return-default-bool", .statement, node, mutants: 2, statement: true)
        case "Int", "UInt", "Int64", "Int32", "UInt64", "UInt32", "UInt8", "Double", "Float", "CGFloat", "TimeInterval":
            add("return-default-number", .statement, node, mutants: 2, statement: true)
        case "String": add("return-default-string", .statement, node, mutants: 2, statement: true)
        case "Void", "()": add("return-early-void", .statement, node, statement: true)
        default:
            if text.hasSuffix("?") {
                add("return-default-nil", .statement, node, statement: true)
            } else if text.hasPrefix("[") || text.hasPrefix("Set<") {
                add("return-default-empty-collection", .statement, node, statement: true)
            } else {
                add("return-default-no-default-value", .statement, node, mutants: 0, statement: true)
            }
        }
    }

    func conditions(_ list: ConditionElementListSyntax) {
        for condition in list {
            switch condition.condition {
            case .expression(let expr):
                add("negate-condition (current)", .expression, expr)
                add("condition-to-constant", .expression, expr, mutants: 2)
            case .optionalBinding(let binding):
                add("optional-binding-to-nil", .expression, binding)
            default: break
            }
        }
    }

    static func awaits(_ expression: ExprSyntax) -> Bool {
        if expression.is(AwaitExprSyntax.self) { return true }
        if let wrapped = expression.as(TryExprSyntax.self) { return awaits(wrapped.expression) }
        return false
    }

    func visitInfixOperatorExpr(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        if let op = node.operator.as(BinaryOperatorExprSyntax.self) {
            switch op.operator.text {
            case "&&", "||": add("logical-replace (current)", .expression, node)
            case "==", "!=": add("relational-equality", .expression, node)
            case "<", "<=", ">", ">=": add("relational-boundary-and-negation", .expression, node, mutants: 2)
            case "+":
                let concatenation = [node.leftOperand, node.rightOperand].contains {
                    $0.is(StringLiteralExprSyntax.self)
                }
                add(concatenation ? "arithmetic-on-string-literal (unviable)" : "arithmetic-replace", .expression, node)
            case "-", "*", "/", "%": add("arithmetic-replace", .expression, node)
            case "+=", "-=", "*=", "/=", "%=": add("compound-assignment-replace", .expression, node)
            case "&", "|", "^", "<<", ">>", "&=", "|=", "^=": add("bitwise-replace", .expression, node)
            case "??": add("nil-coalescing-to-default", .expression, node)
            case "..<", "...": add("range-boundary", .expression, node)
            default: break
            }
        }
        return .visitChildren
    }

    func visitPrefixOperatorExpr(_ node: PrefixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        switch node.operator.text {
        case "!": add("not-removal", .expression, node)
        case "-"
        where !node.expression.is(IntegerLiteralExprSyntax.self)
            && !node.expression.is(FloatLiteralExprSyntax.self):
            add("unary-minus-removal", .expression, node)
        default: break
        }
        return .visitChildren
    }

    func visitStringLiteralExpr(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        guard node.segments.count > 0, node.segments.trimmedDescription != "" else { return .skipChildren }
        // Arguments of logging and assertion calls rarely change observable behaviour.
        var parent = node.parent
        while let current = parent, !current.is(FunctionCallExprSyntax.self), !current.is(CodeBlockItemSyntax.self) {
            parent = current.parent
        }
        let callee = parent?.as(FunctionCallExprSyntax.self)?.calledExpression.trimmedDescription ?? ""
        let logging =
            [
                "print", "debugPrint", "NSLog", "fatalError", "precondition", "preconditionFailure", "assert",
                "assertionFailure", "os_log",
            ].contains(callee)
            || [".debug", ".info", ".notice", ".error", ".warning", ".fault", ".trace", ".log"].contains {
                callee.hasSuffix($0)
            }
        add(logging ? "string-literal-empty (logging argument)" : "string-literal-empty", .expression, node)
        return .skipChildren
    }

    func visitCodeBlockItem(_ node: CodeBlockItemSyntax) -> SyntaxVisitorContinueKind {
        var expression = node.item.as(ExprSyntax.self)
        while let inner = expression {
            if let wrapped = inner.as(TryExprSyntax.self) {
                expression = wrapped.expression
            } else if let wrapped = inner.as(AwaitExprSyntax.self) {
                expression = wrapped.expression
            } else {
                break
            }
        }
        if let call = expression?.as(FunctionCallExprSyntax.self) {
            let name = call.calledExpression.trimmedDescription.split(separator: ".").last.map(String.init) ?? ""
            let cleanup = [
                "close", "cancel", "invalidate", "unlock", "finish", "resume", "removeObserver", "stop",
                "signal", "leave", "removeAll", "flush", "synchronize",
            ].contains(name)
            add(cleanup ? "cleanup-call-removal (fcheck)" : "void-call-removal", .statement, node, statement: true)
        }
        return .visitChildren
    }

    func visitSwitchExpr(_ node: SwitchExprSyntax) -> SyntaxVisitorContinueKind {
        var cases: [SwitchCaseSyntax] = []
        var hasDefault = false
        for element in node.cases {
            guard case .switchCase(let item) = element else { continue }
            if case .default = item.label { hasDefault = true } else { cases.append(item) }
        }
        for item in cases {
            add(hasDefault ? "switch-case-skip (to default)" : "switch-case-skip (no default: unviable)", .clause, item)
        }
        return .visitChildren
    }

    func visitMemberAccessExpr(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        let pairs: Set<String> = [
            "min", "max", "prefix", "suffix", "dropFirst", "dropLast", "hasPrefix", "hasSuffix",
            "uppercased", "lowercased", "popFirst", "popLast", "removeFirst", "removeLast", "startIndex", "endIndex",
        ]
        let transforms: Set<String> = ["sorted", "reversed", "filter", "shuffled"]
        let name = node.declName.baseName.text
        if name == "first" || name == "last" { add("first-last-swap", .expression, node) }
        if pairs.contains(name) { add("collection-method-swap", .expression, node) }
        if name == "trimmingCharacters" { add("collection-method-removal", .expression, node) }
        if transforms.contains(name) { add("collection-transform-removal", .expression, node) }
        if name == "isEmpty" { add("isEmpty-negation", .expression, node) }
        return .visitChildren
    }

    func visitCodeBlockItemList(_ node: CodeBlockItemListSyntax) -> SyntaxVisitorContinueKind {
        // Adjacent statements that both suspend: their order is a scheduling decision (modeler).
        var previousAwaits = false
        for item in node {
            let awaits = item.item.as(ExprSyntax.self).map { Self.awaits($0) } ?? false
            if awaits && previousAwaits { add("await-statement-swap (modeler)", .statement, item, statement: true) }
            previousAwaits = awaits
        }
        return .visitChildren
    }

    func visitPatternBinding(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        if case .getter = node.accessorBlock?.accessors {
            returnDefault(node.typeAnnotation?.type, node)
        }
        return .visitChildren
    }

    func visitAccessorDecl(_ node: AccessorDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.accessorSpecifier.tokenKind == .keyword(.get), node.body != nil,
            let binding = node.parent?.parent?.parent?.as(PatternBindingSyntax.self)
        {
            returnDefault(binding.typeAnnotation?.type, node)
        }
        return .visitChildren
    }

    func visitVariableDecl(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        let isBody = node.bindings.contains {
            $0.pattern.trimmedDescription == "body"
                && $0.typeAnnotation?.type.trimmedDescription.hasPrefix("some ") == true
        }
        if isBody || Self.isBuilder(node.attributes) { builderDepth += 1 }
        return .visitChildren
    }

    func visitFunctionDecl(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if Self.isBuilder(node.attributes)
            || node.signature.returnClause?.type.trimmedDescription.hasPrefix("some ") == true
        {
            builderDepth += 1
        } else if node.body != nil {
            returnDefault(node.signature.returnClause?.type, node)
        }
        return .visitChildren
    }

    func visitPostVariableDecl(_ node: VariableDeclSyntax) {
        let isBody = node.bindings.contains {
            $0.pattern.trimmedDescription == "body"
                && $0.typeAnnotation?.type.trimmedDescription.hasPrefix("some ") == true
        }
        if isBody || Self.isBuilder(node.attributes) { builderDepth -= 1 }
    }

    func visitPostFunctionDecl(_ node: FunctionDeclSyntax) {
        if Self.isBuilder(node.attributes)
            || node.signature.returnClause?.type.trimmedDescription.hasPrefix("some ") == true
        {
            builderDepth -= 1
        }
    }
}
