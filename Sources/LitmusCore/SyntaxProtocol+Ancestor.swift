internal import SwiftSyntax

extension SyntaxProtocol {
    /// Whether some ancestor is a `type`.
    func hasAncestor<T: SyntaxProtocol>(_ type: T.Type) -> Bool {
        var current = parent
        while let node = current {
            if node.is(type) { return true }
            current = node.parent
        }
        return false
    }
}
