/// The initial operator tier; raw values are persistent rule identifiers.
public enum MutationOperator: String, Codable, CaseIterable, Sendable {
    case negateCondition = "negate-condition"
    case swapTernary = "swap-ternary"
    case replaceLogical = "replace-logical"
}

/// A source-accurate edit. Byte offsets refer to the original UTF-8 source, never a rewritten tree.
public struct Mutation: Codable, Equatable, Sendable {
    public let id: String
    public let path: String
    public let line: Int
    public let column: Int
    public let operatorID: MutationOperator
    public let start: Int
    public let end: Int
    public let original: String
    public let replacement: String
    public let sourceFingerprint: String
}

/// A file intentionally left out, or a file that could not be planned. Neither disappears silently.
public struct PlanNote: Codable, Equatable, Sendable {
    public let path: String
    public let reason: String
    public let isDegraded: Bool

    public init(path: String, reason: String, isDegraded: Bool = false) {
        self.path = path; self.reason = reason; self.isDegraded = isDegraded
    }
}

/// A deterministic, versioned discovery artifact. It is not evidence that tests ran.
public struct MutationPlan: Codable, Equatable, Sendable {
    public let version: Int
    public let root: String
    public let analyzedFiles: Int
    public let mutations: [Mutation]
    public let suppressed: [Mutation]
    public let notes: [PlanNote]

    public init(root: String, analyzedFiles: Int, mutations: [Mutation], suppressed: [Mutation] = [], notes: [PlanNote] = []) {
        version = 1; self.root = root; self.analyzedFiles = analyzedFiles
        self.mutations = mutations; self.suppressed = suppressed; self.notes = notes
    }
}

/// Statically discovers mutation candidates without executing the project or its manifest.
public enum MutationPlanner {
    /// Plans one source file; used by corpus discovery as well as embedding clients.
    public static func mutations(in source: String, path: String) throws -> [Mutation] { [] }
}

/// Forms batches whose edits cannot overlap, bounding source growth independently of expression nesting depth.
public enum SchemaWriter {
    /// Partitions sites into deterministic batches. Each site appears exactly once.
    public static func batches(_ mutations: [Mutation], limit: Int = 64) -> [[Mutation]] { [] }
    /// Applies one batch, guarding each replacement with a process-lifetime environment selector.
    public static func render(_ source: String, mutations: [Mutation]) throws -> String { source }
}
