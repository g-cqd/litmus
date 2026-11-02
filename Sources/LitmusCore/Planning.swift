internal import AemiKernel
internal import AemiRuntime
internal import Foundation
internal import ProjectModel
internal import SourceCorpus
internal import Suppression
internal import SwiftOperators
internal import SwiftParser
internal import SwiftSyntax

/// A failure that invalidates an operation rather than manufacturing a partial success.
public struct LitmusFailure: Error, Sendable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Statically discovers candidates; overload resolution and active build conditions are validated by the actual build.
public enum MutationPlanner {
    /// What syntax discovery found in one file.
    public struct Discovery: Sendable, Equatable {
        /// Sites that can be schematised.
        public let sites: [Mutation]
        /// Sites found but deliberately not mutated, with the reason; never dropped silently.
        public let excluded: [ExcludedSite]
    }

    /// A site that exists in the source but is not mutated.
    public struct ExcludedSite: Sendable, Equatable {
        public let site: Mutation
        public let reason: String
    }

    /// Parses and folds standard Swift operators, rejecting malformed or excessively nested input.
    /// - Note: Syntax discovery only; the schema build proves each candidate compiles.
    /// - Complexity: O(*n*) in the syntax nodes of `source`.
    public static func discover(in source: String, path: String) throws -> Discovery {
        let parsed = Parser.parse(source: source)
        guard !parsed.hasError, !SyntaxDepth.exceeds(parsed, limit: 256) else {
            throw LitmusFailure("\(path): invalid syntax or syntax nesting exceeds 256")
        }
        let tree = try OperatorTable.standardOperators.foldAll(parsed)
        let context = SiteContext(
            path: path,
            fingerprint: Digest.sha256(Array(source.utf8)),
            converter: SourceLocationConverter(fileName: path, tree: tree),
            anchors: Anchors(fileText: tree.description)
        )
        let visitor = Sites(context)
        visitor.walk(tree)
        return Discovery(sites: ordered(visitor.sites), excluded: visitor.excluded)
    }

    /// The schematisable sites of one file, in source order.
    public static func mutations(in source: String, path: String) throws -> [Mutation] {
        try discover(in: source, path: path).sites
    }

    static func ordered(_ sites: [Mutation]) -> [Mutation] {
        sites.sorted { ($0.start, $0.end, $0.operatorID.rawValue) < ($1.start, $1.end, $1.operatorID.rawValue) }
    }

    /// Discovers the complete corpus without running package manifests or project scripts.
    /// Uses bounded Aemi concurrency on large stacks; unreadable inputs are explicit degradation, not silent omissions.
    /// - Parameter include: when not empty, only files matching one of these substrings or globs (`PathFilter`'s
    ///   rules; a matching directory covers what is under it) are mutated: "mutate what this change touched".
    /// - Parameter scope: when set, only the changed Swift files are read and only the sites the change reaches are
    ///   planned, those on changed lines first; a change reaching no site is an empty plan, not an error.
    public static func plan(
        root: String,
        exclude: [String] = [],
        include: [String] = [],
        jobs: Int = 4,
        scope: ChangeScope? = nil
    ) async throws -> MutationPlan {
        let root = SourcePath.canonical(root)
        guard FileManager.default.fileExists(atPath: root) else { throw LitmusFailure("root does not exist: \(root)") }
        let filter = PathFilter(exclude + ["Package.swift", "Dangerfile.swift", "**/Plugins/**"], root: root)
        if let scope { return try await plan(root: root, filter: filter, include: include, jobs: jobs, scope: scope) }
        let discovery = SourceDiscovery.discover(under: root, isExcluded: filter.excludes)
        guard !discovery.files.isEmpty else { throw LitmusFailure("no Swift source files under \(root)") }
        var discovered = discovery.files
        if !include.isEmpty {
            let wanted = PathFilter(include, root: root)
            discovered = discovered.filter { wanted.excludes($0) }
            guard !discovered.isEmpty else {
                throw LitmusFailure("no Swift source file matches the include list: \(include.joined(separator: ", "))")
            }
        }
        let classification = ProjectLayout.discover(paths: [root]).map(ProjectClassification.load) ?? .conventionsOnly
        let files = try await mapConcurrently(discovered, limit: min(max(jobs, 1), 16)) { path in
            try Task.checkCancellation()
            return await LargeStack.run {
                planFile(path: path, root: root, classification: classification)
            }
        }
        let issues =
            discovery.unreadableDirectories.map {
                PlanNote(path: $0, reason: "directory could not be read", isDegraded: true)
            }
            + classification.unknownProjects.map {
                PlanNote(path: $0.path, reason: "classification uses conventions: \($0.reason)")
            }
        return MutationPlan(
            root: root,
            analyzedFiles: files.count,
            mutations: files.flatMap(\.mutations),
            suppressed: files.flatMap(\.suppressed),
            notes: issues + files.flatMap(\.notes)
        )
    }

    /// The plan of the changed Swift files only: no directory walk, so a change touching no Swift file costs nothing.
    private static func plan(
        root: String,
        filter: PathFilter,
        include: [String],
        jobs: Int,
        scope: ChangeScope
    ) async throws -> MutationPlan {
        let wanted = include.isEmpty ? nil : PathFilter(include, root: root)
        var files: [String] = []
        var notes: [PlanNote] = []
        for relative in scope.swiftFiles.sorted() {
            let path = root + "/" + relative
            if filter.excludes(path) || wanted.map({ !$0.excludes(path) }) == true {
                notes.append(PlanNote(path: relative, reason: "changed, but excluded by the configuration"))
                continue
            }
            // `attributesOfItem` does not follow a final link: a link is not a regular file.
            let type = (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
            guard type == .typeRegular, SourcePath.canonical(path) == path else {
                // The diff names a file the tree does not have as a regular file: a stale diff, or a link.
                notes.append(
                    PlanNote(path: relative, reason: "changed in the diff, not a regular file here", isDegraded: true)
                )
                continue
            }
            files.append(path)
        }
        let classification = ProjectLayout.discover(paths: [root]).map(ProjectClassification.load) ?? .conventionsOnly
        let planned = try await mapConcurrently(files, limit: min(max(jobs, 1), 16)) { path in
            try Task.checkCancellation()
            return await LargeStack.run { planFile(path: path, root: root, classification: classification) }
        }
        var ranked: [(priority: Int, mutation: Mutation)] = []
        for mutation in planned.flatMap(\.mutations) {
            if let priority = scope.priority(of: mutation) { ranked.append((priority, mutation)) }
        }
        ranked.sort {
            ($0.priority, $0.mutation.path, $0.mutation.start, $0.mutation.id) < (
                $1.priority, $1.mutation.path, $1.mutation.start, $1.mutation.id
            )
        }
        var plan = MutationPlan(
            root: root,
            analyzedFiles: planned.count,
            mutations: ranked.map(\.mutation),
            suppressed: planned.flatMap(\.suppressed).filter { scope.priority(of: $0) != nil },
            notes: notes + planned.flatMap(\.notes)
        )
        plan.scope = PlanScope(
            source: scope.source,
            digest: scope.digest,
            breadth: scope.breadth,
            changedFiles: scope.changed.files.count,
            changedLines: scope.changed.lineCount,
            swiftFiles: scope.swiftFiles.count,
            onChangedLines: ranked.filter { $0.priority == 0 }.map(\.mutation.id)
        )
        return plan
    }

    /// A file a mutation tool may mutate, or why not.
    enum ProductionFile {
        case production(String, SourceFileSyntax)
        case excluded(String)
    }

    /// Reads, parses and classifies one file: test, preview-only, generated and uncompiled files are excluded.
    /// - Throws: when the file is unreadable, not UTF-8, malformed or nested beyond 256 levels.
    static func productionFile(path: String, classification: ProjectClassification) throws -> ProductionFile {
        let bytes = try BoundedFileReader.read(path: path, cap: 2 << 20)
        guard let source = String(bytes: bytes, encoding: .utf8) else { throw LitmusFailure("not UTF-8") }
        let tree = Parser.parse(source: source)
        guard !SyntaxDepth.exceeds(tree, limit: 256), !tree.hasError else {
            throw LitmusFailure("invalid or deeply nested syntax")
        }
        let classified = classification.classify(path)
        if !classified.region.isEmpty || TestConventions.isTestFile(path: path, tree: tree)
            || GeneratedCode.isGenerated(path: path, tree: tree)
        {
            return .excluded("non-production region")
        }
        // A project encloses the file but none of its targets compiles it: every mutant would "survive".
        if case .convention(.unclaimed) = classified.provenance {
            return .excluded("no target of the enclosing project compiles this file")
        }
        return .production(source, tree)
    }

    private static func planFile(path: String, root: String, classification: ProjectClassification) -> MutationPlan {
        let relative = String(path.dropFirst(root.count + 1))
        func excludedFile(_ reason: String) -> MutationPlan {
            MutationPlan(root: root, analyzedFiles: 1, mutations: [], notes: [PlanNote(path: relative, reason: reason)])
        }
        do {
            let (source, tree): (String, SourceFileSyntax)
            switch try productionFile(path: path, classification: classification) {
            case .excluded(let reason): return excludedFile(reason)
            case .production(let text, let parsed): (source, tree) = (text, parsed)
            }
            let converter = SourceLocationConverter(fileName: path, tree: tree)
            let spans = CodeRegionScanner.scan(tree, converter: converter)
            let grammar = DirectiveGrammar(namespaces: ["lm:", "litmus:"])
            let directives: [Directive<MutationOperator>] = grammar.scan(tree: tree, converter: converter) {
                comment,
                line in
                grammar.parse(comment: comment, line: line, rule: MutationOperator.init(rawValue:))
            }
            let table = SuppressionTable(directives: directives)
            let found = try discover(in: source, path: relative)
            var active: [Mutation] = [], suppressed: [Mutation] = []
            var notes = found.excluded.map { PlanNote(path: relative, reason: "\($0.site.id): \($0.reason)") }
            for mutation in found.sites {
                if spans.contains(where: { $0.startLine <= mutation.line && mutation.line <= $0.endLine }) {
                    notes.append(
                        PlanNote(path: relative, reason: "\(mutation.id): preview/debug-only site excluded by policy")
                    )
                } else if table.suppression(for: mutation.operatorID, line: mutation.line) != nil {
                    suppressed.append(mutation)
                } else {
                    active.append(mutation)
                }
            }
            return MutationPlan(root: root, analyzedFiles: 1, mutations: active, suppressed: suppressed, notes: notes)
        } catch {
            return MutationPlan(
                root: root,
                analyzedFiles: 1,
                mutations: [],
                notes: [PlanNote(path: relative, reason: "\(error)", isDegraded: true)]
            )
        }
    }
}

private struct SiteContext {
    let path: String
    let fingerprint: String
    let converter: SourceLocationConverter
    let anchors: Anchors
}

/// The enclosing declarations of the walk, and how many identical sites each has had: what anchors a mutant's
/// identity to the code (ADR 0007) rather than to byte offsets, which every edit above it would change.
private final class Anchors {
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

    init(fileText: String) { self.fileText = fileText }

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

/// `text` with every run of whitespace replaced by one space, and none at either end (analyzerkit's anchored
/// fingerprint normalisation).
func normalized(_ text: String) -> String {
    text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).joined(separator: " ")
}

/// A function-like declaration's name with its argument labels: `name(_:label:)`.
private func signature(_ name: String, _ parameters: FunctionParameterListSyntax) -> String {
    name + "(" + parameters.map { ($0.firstName.text) + ":" }.joined() + ")"
}

private final class Sites: SyntaxVisitor {
    let context: SiteContext
    var sites: [Mutation] = []
    var excluded: [MutationPlanner.ExcludedSite] = []

    init(_ context: SiteContext) {
        self.context = context
        super.init(viewMode: .sourceAccurate)
    }

    private func add(_ expression: ExprSyntax, operatorID: MutationOperator, replacement: String) {
        let start = expression.positionAfterSkippingLeadingTrivia.utf8Offset
        let end = expression.endPositionBeforeTrailingTrivia.utf8Offset
        let original = expression.trimmedDescription
        let location = context.converter.location(for: expression.positionAfterSkippingLeadingTrivia)
        // Anchored identity: the path, the enclosing declaration, the operator, the site's normalised text and
        // replacement, and which identical site of the declaration it is. Lines added above leave it unchanged.
        let declaration = context.anchors.path
        let anchor =
            "\(context.path)\u{0}\(declaration)\u{0}\(operatorID.rawValue)\u{0}\(normalized(original))\u{0}"
            + normalized(replacement)
        let key = anchor + "\u{0}\(context.anchors.ordinal(anchor))"
        let hash = String(XXH64.hash(Array(key.utf8)), radix: 16)
        let id = String(repeating: "0", count: 16 - hash.count) + hash
        sites.append(
            Mutation(
                id: id,
                path: context.path,
                line: location.line,
                column: location.column,
                operatorID: operatorID,
                start: start,
                end: end,
                original: original,
                replacement: replacement,
                sourceFingerprint: context.fingerprint,
                declaration: declaration,
                declarationDigest: Digest.sha256(Array(context.anchors.bodyText.utf8))
            )
        )
    }

    // Declarations, for anchored identities: pushed on the way in, popped on the way out.
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { enter(node.name.text, node) }
    override func visitPost(_ node: StructDeclSyntax) { context.anchors.pop() }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { enter(node.name.text, node) }
    override func visitPost(_ node: ClassDeclSyntax) { context.anchors.pop() }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { enter(node.name.text, node) }
    override func visitPost(_ node: EnumDeclSyntax) { context.anchors.pop() }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind { enter(node.name.text, node) }
    override func visitPost(_ node: ActorDeclSyntax) { context.anchors.pop() }
    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind { enter(node.name.text, node) }
    override func visitPost(_ node: ProtocolDeclSyntax) { context.anchors.pop() }
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        enter(normalized(node.extendedType.trimmedDescription), node)
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { context.anchors.pop() }
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        enter(signature(node.name.text, node.signature.parameterClause.parameters), node, body: true)
    }
    override func visitPost(_ node: FunctionDeclSyntax) { context.anchors.pop() }
    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        enter(
            signature("init" + (node.optionalMark?.text ?? ""), node.signature.parameterClause.parameters),
            node,
            body: true
        )
    }
    override func visitPost(_ node: InitializerDeclSyntax) { context.anchors.pop() }
    override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        enter("deinit", node, body: true)
    }
    override func visitPost(_ node: DeinitializerDeclSyntax) { context.anchors.pop() }
    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        enter(signature("subscript", node.parameterClause.parameters), node, body: true)
    }
    override func visitPost(_ node: SubscriptDeclSyntax) { context.anchors.pop() }
    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        let names = node.bindings.map { normalized($0.pattern.trimmedDescription) }.joined(separator: ",")
        return enter(names, node, body: true)
    }
    override func visitPost(_ node: VariableDeclSyntax) { context.anchors.pop() }
    override func visit(_ node: AccessorDeclSyntax) -> SyntaxVisitorContinueKind {
        enter(node.accessorSpecifier.text, node, body: true)
    }
    override func visitPost(_ node: AccessorDeclSyntax) { context.anchors.pop() }

    private func enter(_ name: String, _ node: some SyntaxProtocol, body: Bool = false) -> SyntaxVisitorContinueKind {
        context.anchors.push(name, isBody: body, node)
        return .visitChildren
    }

    override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
        conditions(node.conditions)
        return .visitChildren
    }
    override func visit(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind {
        conditions(node.conditions)
        return .visitChildren
    }
    override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind {
        conditions(node.conditions)
        return .visitChildren
    }
    private func conditions(_ list: ConditionElementListSyntax) {
        for condition in list {
            if case .expression(let expr) = condition.condition {
                add(expr, operatorID: .negateCondition, replacement: "!(\(expr.trimmedDescription))")
            }
        }
    }
    override func visit(_ node: TernaryExprSyntax) -> SyntaxVisitorContinueKind {
        add(node.condition, operatorID: .swapTernary, replacement: "!(\(node.condition.trimmedDescription))")
        return .visitChildren
    }
    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        guard let op = node.operator.as(BinaryOperatorExprSyntax.self), ["&&", "||"].contains(op.operator.text) else {
            return .visitChildren
        }
        let other = op.operator.text == "&&" ? "||" : "&&"
        // Operands keep their folded grouping: `a || b || c` is `(a || b) || c`, whose outer mutant is
        // `(a || b) && (c)`, not the regrouped text `a || b && c`.
        add(
            ExprSyntax(node),
            operatorID: .replaceLogical,
            replacement: "(\(node.leftOperand.trimmedDescription)) \(other) (\(node.rightOperand.trimmedDescription))"
        )
        return .visitChildren
    }
    override func visit(_ node: IfConfigClauseSyntax) -> SyntaxVisitorContinueKind {
        // The condition is compile-time syntax, not a runtime Boolean expression.
        if let elements = node.elements { walk(elements) }
        return .skipChildren
    }
    // A macro rewrites its arguments as syntax (`#Predicate`, `#expect`): a schema inside one is not plain Swift.
    override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        excludeInside(node)
    }
    override func visit(_ node: MacroExpansionDeclSyntax) -> SyntaxVisitorContinueKind {
        excludeInside(node)
    }
    private func excludeInside(_ node: some SyntaxProtocol) -> SyntaxVisitorContinueKind {
        let inner = Sites(context)
        for child in node.children(viewMode: .sourceAccurate) { inner.walk(child) }
        excluded += (inner.sites + inner.excluded.map(\.site)).map {
            MutationPlanner.ExcludedSite(site: $0, reason: "inside a macro expansion; not mutated")
        }
        return .skipChildren
    }
}

/// Cryptographic content identity for execution validity, distinct from fast diagnostic identities.
public enum Digest {
    /// Lower-case hexadecimal SHA-256 of `bytes`: aemi's `ContentDigest` (CommonCrypto on Apple platforms, a portable
    /// FIPS 180-4 implementation elsewhere; aemi ADR 0028), where CryptoKit tied Litmus to Apple platforms.
    public static func sha256(_ bytes: [UInt8]) -> String {
        ContentDigest.sha256Hex(bytes)
    }
}
