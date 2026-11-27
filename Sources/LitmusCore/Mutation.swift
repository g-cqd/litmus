internal import Foundation

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
    /// The enclosing declaration's path (`Type.method(_:)`, empty at file scope), part of the anchored identity.
    public var declaration: String? = nil
    /// SHA-256 of the whitespace-normalised text of the outermost enclosing body declaration (function, accessor,
    /// property...), or of the file at file scope: what `--reuse declaration` compares.
    public var declarationDigest: String? = nil

    public init(
        id: String,
        path: String,
        line: Int,
        column: Int,
        operatorID: MutationOperator,
        start: Int,
        end: Int,
        original: String,
        replacement: String,
        sourceFingerprint: String,
        declaration: String? = nil,
        declarationDigest: String? = nil
    ) {
        self.id = id
        self.path = path
        self.line = line
        self.column = column
        self.operatorID = operatorID
        self.start = start
        self.end = end
        self.original = original
        self.replacement = replacement
        self.sourceFingerprint = sourceFingerprint
        self.declaration = declaration
        self.declarationDigest = declarationDigest
    }

    /// The last line of the mutated expression.
    public var endLine: Int { line + original.count(where: { $0 == "\n" }) }

    /// How `SchemaWriter` splices this site: clause replacements carry `SchemaWriter.clauseGuardPlaceholder` (e.g.
    /// shorthand `if let x`), while initialized `if let x = expr` sites use `.expression` so inner sites nest.
    public var effectiveShape: SchemaShape {
        replacement.contains(SchemaWriter.clauseGuardPlaceholder) ? .clause : operatorID.shape
    }
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
    /// The change the plan is limited to (`--diff`, `--diff-base`); nil for a whole-subject plan.
    public var scope: PlanScope? = nil
    /// Non-mutated sites summarised by reason (e.g. view-builder statements skipped by `remove-call`), so reports can
    /// explain omissions without inflating findings or breaking older artifacts.
    public var skipped: [String: Int]? = nil
    /// What `.litmus-accepted.json` decided for this plan; nil when no acceptance file was read.
    public var acceptance: AcceptanceRecord? = nil

    public init(
        root: String,
        analyzedFiles: Int,
        mutations: [Mutation],
        suppressed: [Mutation] = [],
        notes: [PlanNote] = []
    ) {
        version = 1; self.root = root; self.analyzedFiles = analyzedFiles
        self.mutations = mutations; self.suppressed = suppressed; self.notes = notes
    }
}
