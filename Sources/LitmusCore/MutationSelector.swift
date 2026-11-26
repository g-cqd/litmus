/// One `--only-id` selector: a mutant id (16 hex digits, or an unambiguous prefix of at least 8), or a location
/// `path:line[:operator]` whose path matches a mutant's relative path whole or by its trailing components.
public struct MutationSelector: Sendable, Equatable, CustomStringConvertible {
    enum Kind: Sendable, Equatable {
        case id(String)
        case location(path: String, line: Int, operatorID: MutationOperator?)
    }

    let kind: Kind
    public let description: String

    /// - Throws: `LitmusFailure` for an id shorter than 8 or longer than 16 hex digits, a line that is not a positive
    ///   number, or an unknown operator.
    public init(parsing text: String) throws {
        description = text
        let lowered = text.lowercased()
        if !text.contains(":") {
            guard (8...16).contains(lowered.count), lowered.allSatisfy(\.isHexDigit) else {
                throw LitmusFailure(
                    "--only-id \(text): expected a mutant id (8 to 16 hex digits) or path:line[:operator]"
                )
            }
            kind = .id(lowered)
            return
        }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), !parts[0].isEmpty, let line = Int(parts[1]), line >= 1 else {
            throw LitmusFailure("--only-id \(text): expected path:line[:operator] with a positive line")
        }
        var operatorID: MutationOperator?
        if parts.count == 3 {
            guard let known = MutationOperator(rawValue: String(parts[2])) else {
                throw LitmusFailure("--only-id \(text): unknown operator \(parts[2])")
            }
            operatorID = known
        }
        kind = .location(path: String(parts[0]), line: line, operatorID: operatorID)
    }

    func matches(_ mutation: Mutation) -> Bool {
        switch kind {
        case .id(let id):
            return mutation.id.hasPrefix(id)
        case .location(let path, let line, let operatorID):
            guard mutation.path == path || mutation.path.hasSuffix("/" + path) else { return false }
            guard (mutation.line...mutation.endLine).contains(line) else { return false }
            return operatorID.map { $0 == mutation.operatorID } ?? true
        }
    }

    /// The mutants of `mutations` that any selector matches, in their order, each once.
    /// - Throws: `LitmusFailure` when a selector matches nothing, or an id prefix matches more than one mutant.
    /// - Complexity: O(*n* · *s*) for *n* mutations and *s* selectors.
    public static func select(_ mutations: [Mutation], by selectors: [Self]) throws -> [Mutation] {
        var chosen: Set<String> = []
        for selector in selectors {
            let matched = mutations.filter(selector.matches)
            guard !matched.isEmpty else {
                throw LitmusFailure("--only-id \(selector): no planned mutant matches (check `litmus plan`)")
            }
            if case .id = selector.kind, matched.count > 1 {
                throw LitmusFailure(
                    "--only-id \(selector): the prefix matches \(matched.count) mutants; give more digits"
                )
            }
            chosen.formUnion(matched.map(\.id))
        }
        return mutations.filter { chosen.contains($0.id) }
    }
}
