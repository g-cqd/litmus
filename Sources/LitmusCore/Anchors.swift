internal import SwiftSyntax

/// The enclosing declarations of the walk, and how many identical sites each has had: what anchors a mutant's
/// identity to the code rather than to byte offsets, which every edit above it would change.
final class Anchors {
    struct Declaration {
        let name: String
        /// Named code whose text a mutant's verdict can depend on (function, initializer, accessor, property...); a
        /// type or an extension only names its members.
        let isBody: Bool
        let text: String
    }
    private(set) var stack: [Declaration] = []
    private var ordinals: [String: Int] = [:]
    private let fileText: String
    let sourceUTF8: [UInt8]

    init(fileText: String) {
        self.fileText = fileText
        self.sourceUTF8 = Array(fileText.utf8)
    }

    func push(_ name: String, isBody: Bool, _ node: some SyntaxProtocol) {
        stack.append(Declaration(name: name, isBody: isBody, text: isBody ? node.trimmedDescription : ""))
    }
    func pop() { stack.removeLast() }

    /// `Type.method(_:label:)` for the current position; empty at file scope.
    var path: String { stack.map(\.name).joined(separator: ".") }

    /// The whitespace-normalised text of the outermost body declaration (the member: a local function or variable is
    /// part of it), or of the file at file scope.
    var bodyText: String { normalized(stack.first(where: \.isBody)?.text ?? fileText) }

    /// The ordinal of the next site with this key, counting from 0.
    func ordinal(_ key: String) -> Int {
        defer { ordinals[key, default: 0] += 1 }
        return ordinals[key, default: 0]
    }
}
