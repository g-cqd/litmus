internal import Foundation
internal import CryptoKit
internal import AemiKernel
internal import AemiRuntime
internal import SwiftSyntax
internal import SwiftParser
internal import SwiftOperators
internal import SourceCorpus
internal import ProjectModel
internal import Suppression

/// A failure that invalidates an operation rather than manufacturing a partial success.
public struct LitmusFailure: Error, Sendable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Statically discovers candidates; overload resolution and active build conditions are validated by the actual build.
public enum MutationPlanner {
    /// Parses and folds standard Swift operators, rejecting malformed or excessively nested input.
    /// - Note: This is syntax discovery, not proof that a candidate has stdlib Bool semantics.
    public static func mutations(in source: String, path: String) throws -> [Mutation] {
        let parsed = Parser.parse(source: source)
        guard !parsed.hasError, !SyntaxDepth.exceeds(parsed, limit: 256) else {
            throw LitmusFailure("\(path): invalid syntax or syntax nesting exceeds 256")
        }
        let tree = try OperatorTable.standardOperators.foldAll(parsed)
        let visitor = Sites(path: path, source: source, tree: tree)
        visitor.walk(tree)
        return visitor.sites.sorted { ($0.start, $0.end, $0.operatorID.rawValue) < ($1.start, $1.end, $1.operatorID.rawValue) }
    }

    /// Discovers the complete corpus without running package manifests or project scripts.
    /// Uses bounded Aemi concurrency; unreadable inputs are explicit degradation, not silent omissions.
    public static func plan(root: String, exclude: [String] = [], jobs: Int = 4) async throws -> MutationPlan {
        let root = SourcePath.canonical(root)
        guard FileManager.default.fileExists(atPath: root) else { throw LitmusFailure("root does not exist: \(root)") }
        let filter = PathFilter(exclude + ["Package.swift", "Dangerfile.swift", "**/Plugins/**"], root: root)
        let discovery = SourceDiscovery.discover(under: root, isExcluded: filter.excludes)
        guard !discovery.files.isEmpty else { throw LitmusFailure("no Swift source files under \(root)") }
        let classification = ProjectLayout.discover(paths: [root]).map(ProjectClassification.load) ?? .conventionsOnly
        let files = try await mapConcurrently(discovery.files, limit: min(max(jobs, 1), 16)) { path in
            try Task.checkCancellation()
            return await LargeStack.run {
                planFile(path: path, root: root, classification: classification)
            }
        }
        let issues = discovery.unreadableDirectories.map {
            PlanNote(path: $0, reason: "directory could not be read", isDegraded: true)
        } + classification.unknownProjects.map {
            PlanNote(path: $0.path, reason: "classification uses conventions: \($0.reason)")
        }
        return MutationPlan(root: root, analyzedFiles: files.count,
            mutations: files.flatMap(\.mutations), suppressed: files.flatMap(\.suppressed),
            notes: issues + files.flatMap(\.notes))
    }

    private static func planFile(path: String, root: String, classification: ProjectClassification) -> MutationPlan {
        let relative = String(path.dropFirst(root.count + 1))
        do {
            let bytes = try BoundedFileReader.read(path: path, cap: 2 << 20)
            guard let source = String(bytes: bytes, encoding: .utf8) else { throw LitmusFailure("not UTF-8") }
            let tree = Parser.parse(source: source)
            guard !SyntaxDepth.exceeds(tree, limit: 256), !tree.hasError else { throw LitmusFailure("invalid or deeply nested syntax") }
            let region = classification.classify(path).region
            if !region.isEmpty || TestConventions.isTestFile(path: path, tree: tree) || GeneratedCode.isGenerated(path: path, tree: tree) {
                return MutationPlan(root: root, analyzedFiles: 1, mutations: [], notes: [PlanNote(path: relative, reason: "non-production region")])
            }
            let converter = SourceLocationConverter(fileName: path, tree: tree)
            let spans = CodeRegionScanner.scan(tree, converter: converter)
            let grammar = DirectiveGrammar(namespaces: ["lm:", "litmus:"])
            let directives: [Directive<MutationOperator>] = grammar.scan(tree: tree, converter: converter) { comment, line in
                grammar.parse(comment: comment, line: line, rule: MutationOperator.init(rawValue:))
            }
            let table = SuppressionTable(directives: directives)
            let all = try mutations(in: source, path: relative)
            var active: [Mutation] = [], suppressed: [Mutation] = [], notes: [PlanNote] = []
            for mutation in all {
                if spans.contains(where: { $0.startLine <= mutation.line && mutation.line <= $0.endLine }) {
                    notes.append(PlanNote(path: relative, reason: "\(mutation.id): preview/debug-only site excluded by policy"))
                } else if table.suppression(for: mutation.operatorID, line: mutation.line) != nil {
                    suppressed.append(mutation)
                } else { active.append(mutation) }
            }
            return MutationPlan(root: root, analyzedFiles: 1, mutations: active, suppressed: suppressed, notes: notes)
        } catch {
            return MutationPlan(root: root, analyzedFiles: 1, mutations: [], notes: [PlanNote(path: relative, reason: "\(error)", isDegraded: true)])
        }
    }
}

private final class Sites: SyntaxVisitor {
    let path: String
    let fingerprint: String
    let converter: SourceLocationConverter
    var sites: [Mutation] = []

    init(path: String, source: String, tree: some SyntaxProtocol) {
        self.path = path
        fingerprint = Digest.sha256(Array(source.utf8))
        converter = SourceLocationConverter(fileName: path, tree: tree)
        super.init(viewMode: .sourceAccurate)
    }

    private func add(_ expression: ExprSyntax, operatorID: MutationOperator, replacement: String) {
        let start = expression.positionAfterSkippingLeadingTrivia.utf8Offset
        let end = expression.endPositionBeforeTrailingTrivia.utf8Offset
        let original = expression.trimmedDescription
        let location = converter.location(for: expression.positionAfterSkippingLeadingTrivia)
        let key = "\(path)\u{0}\(start)\u{0}\(end)\u{0}\(operatorID.rawValue)\u{0}\(original)"
        let id = String(XXH64.hash(Array(key.utf8)), radix: 16)
        sites.append(Mutation(id: id, path: path, line: location.line, column: location.column,
            operatorID: operatorID, start: start, end: end, original: original, replacement: replacement,
            sourceFingerprint: fingerprint))
    }

    override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
        conditions(node.conditions); return .visitChildren
    }
    override func visit(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind {
        conditions(node.conditions); return .visitChildren
    }
    override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind {
        conditions(node.conditions); return .visitChildren
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
        guard let op = node.operator.as(BinaryOperatorExprSyntax.self), ["&&", "||"].contains(op.operator.text) else { return .visitChildren }
        let other = op.operator.text == "&&" ? "||" : "&&"
        add(ExprSyntax(node), operatorID: .replaceLogical,
            replacement: "\(node.leftOperand.trimmedDescription) \(other) \(node.rightOperand.trimmedDescription)")
        return .visitChildren
    }
    override func visit(_ node: IfConfigClauseSyntax) -> SyntaxVisitorContinueKind {
        // The condition is compile-time syntax, not a runtime Boolean expression.
        if let elements = node.elements { walk(elements) }
        return .skipChildren
    }
}

/// Cryptographic content identity for execution validity, distinct from fast diagnostic identities.
public enum Digest {
    public static func sha256(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: bytes).map { byte in
            let hex = String(byte, radix: 16)
            return byte < 16 ? "0" + hex : hex
        }.joined()
    }
}
