internal import SwiftSyntax

/// Which call statements `remove-call` leaves alone, and which calls are arid.
enum CallRemoval {
    private static let names: Set<String> = [
        "print", "debugPrint", "dump", "NSLog", "os_log", "assert", "assertionFailure", "precondition",
        "preconditionFailure", "fatalError", "swift_unreachable",
        // Waits change only timing: removing one is a mutant no test should have to catch.
        "sleep", "usleep", "nanosleep", "Task.yield",
    ]
    private static let loggerMethods: Set<String> = [
        "debug", "info", "notice", "error", "warning", "fault", "trace", "critical", "log",
    ]
    private static let lockOrSyncNames: Set<String> = [
        "sync", "withLock", "withUnsafeBytes", "withUnsafeMutableBytes", "withUnsafeBufferPointer",
        "withUnsafeMutableBufferPointer", "withCheckedContinuation", "withCheckedThrowingContinuation",
        "withUnsafeContinuation", "withUnsafeThrowingContinuation", "withExtendedLifetime", "autoreleasepool",
        "assumeIsolated",
    ]

    private static let cleanupNames: Set<String> = [
        "close", "cancel", "invalidate", "finish", "removeObserver", "stop", "leave", "removeAll", "flush",
        "synchronize", "disconnect", "unsubscribe",
    ]
    private static let unlockNames: Set<String> = [
        "unlock", "os_unfair_lock_unlock", "pthread_mutex_unlock", "pthread_rwlock_unlock", "signal",
    ]

    static func isCleanupCall(_ callee: String) -> Bool {
        let last = callee.split(separator: ".").last.map(String.init) ?? callee
        return cleanupNames.contains(last)
    }

    /// True if `statements` calls an unlock/signal primitive (skipping such a `defer` deadlocks every later test).
    static func containsLockUnlock(_ statements: CodeBlockItemListSyntax) -> Bool {
        for item in statements {
            if let expr = item.item.as(ExprSyntax.self),
                let call = unwrapTryAwait(expr).as(FunctionCallExprSyntax.self)
            {
                let callee = call.calledExpression.trimmedDescription
                let last = callee.split(separator: ".").last.map(String.init) ?? callee
                if unlockNames.contains(callee) || unlockNames.contains(last) { return true }
            }
        }
        return false
    }

    /// Logging, assertions, waits, and initializer chaining: removing them proves nothing or cannot compile.
    static func isLogging(_ callee: String) -> Bool {
        if callee == "super.init" || callee == "self.init" { return true }
        let last = callee.split(separator: ".").last.map(String.init) ?? callee
        if names.contains(callee) || names.contains(last) { return true }
        return callee.contains(".") && loggerMethods.contains(last)
    }

    /// True if expression mutations inside the call's arguments should also be suppressed (`debugPrint`, `dump`,
    /// `NSLog`, `os_log`, `Logger.*`, and user-configured `aridCalls`). Plain `print(...)` stays mutable inside its
    /// arguments because CLI programs produce observable output through `print`.
    static func isAridExpressionScope(_ callee: String, aridCalls: [String]) -> Bool {
        let last = callee.split(separator: ".").last.map(String.init) ?? callee
        let debugNames: Set<String> = ["debugPrint", "dump", "NSLog", "os_log"]
        if debugNames.contains(callee) || debugNames.contains(last) { return true }
        if callee.contains(".") && loggerMethods.contains(last) { return true }
        return matchesUserArid(callee, last: last, aridCalls: aridCalls)
    }

    /// True if `callee` matches the built-in logging/assertion list or any user-configured `aridCalls` entry.
    static func isArid(_ callee: String, aridCalls: [String]) -> Bool {
        if isLogging(callee) { return true }
        let last = callee.split(separator: ".").last.map(String.init) ?? callee
        return matchesUserArid(callee, last: last, aridCalls: aridCalls)
    }

    private static func matchesUserArid(_ callee: String, last: String, aridCalls: [String]) -> Bool {
        guard !aridCalls.isEmpty else { return false }
        for pattern in aridCalls where !pattern.isEmpty {
            if matchesWildcard(callee, pattern: pattern)
                || matchesWildcard(last, pattern: pattern)
                || callee.hasPrefix(pattern + ".")
                || callee.hasPrefix(pattern + "(")
            {
                return true
            }
        }
        return false
    }

    static func unwrapTryAwait(_ expression: ExprSyntax) -> ExprSyntax {
        var current = expression
        while true {
            if let wrapped = current.as(TryExprSyntax.self) {
                current = wrapped.expression
            } else if let wrapped = current.as(AwaitExprSyntax.self) {
                current = wrapped.expression
            } else {
                return current
            }
        }
    }

    /// True if every statement in `statements` is an arid call statement.
    static func isAllArid(_ statements: CodeBlockItemListSyntax, aridCalls: [String]) -> Bool {
        guard !statements.isEmpty else { return true }
        for item in statements {
            guard let expr = item.item.as(ExprSyntax.self),
                let call = unwrapTryAwait(expr).as(FunctionCallExprSyntax.self),
                isArid(call.calledExpression.trimmedDescription, aridCalls: aridCalls)
            else { return false }
        }
        return true
    }

    /// True for synchronous wrapper calls (`withLock`, `DispatchQueue.sync`, `autoreleasepool`, `assumeIsolated`, ...)
    /// whose trailing closure should not be emptied as an asynchronous callback.
    static func isLockOrSyncWrapper(_ callee: String) -> Bool {
        let last = callee.split(separator: ".").last.map(String.init) ?? callee
        return lockOrSyncNames.contains(callee) || lockOrSyncNames.contains(last)
    }

    /// Simple `*` wildcard matcher over whole names.
    static func matchesWildcard(_ text: String, pattern: String) -> Bool {
        guard pattern.contains("*") else { return text == pattern }
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        if parts.allSatisfy(\.isEmpty) { return true }
        var remainder = text[...]
        for (index, part) in parts.enumerated() {
            if part.isEmpty { continue }
            if index == 0 {
                guard remainder.hasPrefix(part) else { return false }
                remainder = remainder.dropFirst(part.count)
            } else if index == parts.count - 1 {
                return remainder.hasSuffix(part)
            } else {
                guard let range = remainder.range(of: part) else { return false }
                remainder = remainder[range.upperBound...]
            }
        }
        return parts.last?.isEmpty == true || remainder.isEmpty
    }

    /// The call is the only statement of a body whose value it may be returned as: a closure, a getter, or a function
    /// with a result. Wrapping it in `if` would change that body's type.
    static func isImplicitReturn(_ node: CodeBlockItemSyntax) -> Bool {
        guard let list = node.parent?.as(CodeBlockItemListSyntax.self), let owner = list.parent else { return false }
        // The last statement of a `guard`'s else must leave the scope: a call there returns `Never`.
        if node == list.last, owner.as(CodeBlockSyntax.self)?.parent?.is(GuardStmtSyntax.self) == true { return true }
        // The last statement of an `if` or `switch` used as a value is that branch's value.
        if node == list.last, let branch = valueBranch(owner) { return branch }
        guard list.count == 1 else { return false }
        if owner.is(ClosureExprSyntax.self) || owner.is(AccessorBlockSyntax.self) { return true }
        guard let block = owner.as(CodeBlockSyntax.self), let holder = block.parent else { return false }
        if let accessor = holder.as(AccessorDeclSyntax.self) {
            return accessor.accessorSpecifier.tokenKind == .keyword(.get)
                || accessor.accessorSpecifier.tokenKind == .keyword(._read)
                || accessor.accessorSpecifier.tokenKind == .keyword(._modify)
        }
        if let function = holder.as(FunctionDeclSyntax.self) {
            return returnsValue(function.signature.returnClause)
        }
        return false
    }

    /// For a body that is a branch of an `if` or `switch`: whether that `if` or `switch` is used as a value (an
    /// expression, or the implicit return of its own body). Nil for any other body.
    private static func valueBranch(_ owner: Syntax) -> Bool? {
        var statement: Syntax?
        if let block = owner.as(CodeBlockSyntax.self), let holder = block.parent {
            if holder.is(IfExprSyntax.self) {
                // `else if` chains nest: climb to the outermost `if`.
                var top = holder
                while let parent = top.parent, parent.is(IfExprSyntax.self) { top = parent }
                statement = top
            } else {
                return nil
            }
        } else if owner.is(SwitchCaseSyntax.self) {
            statement = owner.parent?.parent  // SwitchCaseList → SwitchExpr
            guard statement?.is(SwitchExprSyntax.self) == true else { return nil }
        } else {
            return nil
        }
        guard let statement else { return nil }
        // A statement `if`/`switch` sits in an expression statement of a code block item.
        let item = statement.parent?.as(ExpressionStmtSyntax.self)?.parent ?? statement.parent
        guard let item = item?.as(CodeBlockItemSyntax.self) else { return true }
        return isImplicitReturn(item)
    }

    static func returnsValue(_ clause: ReturnClauseSyntax?) -> Bool {
        guard let type = clause?.type.trimmedDescription else { return false }
        return !["Void", "()", "Swift.Void"].contains(type)
    }
}
