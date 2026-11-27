internal import Foundation
internal import ProjectModel
internal import SourceCorpus
internal import Suppression
internal import SwiftParser
internal import SwiftSyntax

extension MutationPlanner {
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

    static func planFile(
        path: String,
        root: String,
        classification: ProjectClassification,
        operators: Set<MutationOperator>,
        aridCalls: [String] = [],
        excludeDeclarations: [String] = [],
        oracle: TypeOracle = .empty()
    ) -> MutationPlan {
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
            var unknownDirectives: [PlanNote] = []
            let directives: [Directive<MutationOperator>] = grammar.scan(tree: tree, converter: converter) {
                comment,
                line in
                let parsed = grammar.parse(comment: comment, line: line, rule: MutationOperator.init(rawValue:))
                if parsed == nil,
                    let bad = Self.unknownDirectiveRule(in: comment, namespaces: ["lm:", "litmus:"])
                {
                    unknownDirectives.append(
                        PlanNote(
                            path: relative,
                            reason: "line \(line): unknown operator '\(bad)' in directive; directive ignored"
                        )
                    )
                }
                return parsed
            }
            let table = SuppressionTable(directives: directives)
            let found = try discover(
                in: source,
                path: relative,
                operators: operators,
                aridCalls: aridCalls,
                excludeDeclarations: excludeDeclarations,
                oracle: oracle
            )
            var active: [Mutation] = [], suppressed: [Mutation] = []
            var notes =
                unknownDirectives
                + found.excluded.map { PlanNote(path: relative, reason: "\($0.site.id): \($0.reason)") }
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
            var filePlan = MutationPlan(
                root: root,
                analyzedFiles: 1,
                mutations: active,
                suppressed: suppressed,
                notes: notes
            )
            filePlan.skipped = found.skipped.isEmpty ? nil : found.skipped
            return filePlan
        } catch {
            return MutationPlan(
                root: root,
                analyzedFiles: 1,
                mutations: [],
                notes: [PlanNote(path: relative, reason: "\(error)", isDegraded: true)]
            )
        }
    }

    /// Detects a `@lm:accept... <rule>` or `@litmus:accept... <rule>` comment whose `<rule>` is not a known
    /// `MutationOperator`, so typos are reported in `PlanNote`s instead of silently failing to suppress.
    static func unknownDirectiveRule(in comment: String, namespaces: [String]) -> String? {
        for ns in namespaces {
            guard let range = comment.range(of: "@" + ns) else { continue }
            let after = comment[range.upperBound...]
            let beforeReason = after.components(separatedBy: "--").first ?? String(after)
            let tokens = beforeReason.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," })
            guard let action = tokens.first,
                ["accept", "accept:next", "accept:line", "accept:start", "accept:end"].contains(String(action))
            else { continue }
            for token in tokens.dropFirst() {
                let name = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "*/"))
                guard !name.isEmpty, name != "all" else { continue }
                if MutationOperator(rawValue: name) == nil { return name }
            }
        }
        return nil
    }
}
