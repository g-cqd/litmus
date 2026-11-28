internal import AemiDigest
internal import AemiKernel
internal import AemiRuntime
internal import Foundation
internal import ProjectModel
internal import ReportSupport
internal import SourceCorpus
internal import Suppression
internal import SwiftOperators
internal import SwiftParser
internal import SwiftSyntax

/// Statically discovers candidates; overload resolution and active build conditions are validated by the actual build.
public enum MutationPlanner {
    /// Reason key recorded in `MutationPlan.skipped` when `remove-call` leaves SwiftUI view-builder leaf elements
    /// untouched (opt in with `--operators remove-view-element`).
    public static let skippedViewBuilderReason =
        "SwiftUI view-builder leaf element(s) left alone (opt in: remove-view-element)"

    /// What syntax discovery found in one file.
    public struct Discovery: Sendable, Equatable {
        /// Sites that can be schematised.
        public let sites: [Mutation]
        /// Sites found but deliberately not mutated, with the reason; never dropped silently.
        public let excluded: [ExcludedSite]
        /// Counts of sites skipped by context policy (e.g. view-builder statements left alone by `remove-call`).
        public let skipped: [String: Int]

        public init(sites: [Mutation], excluded: [ExcludedSite], skipped: [String: Int] = [:]) {
            self.sites = sites
            self.excluded = excluded
            self.skipped = skipped
        }
    }

    /// A site that exists in the source but is not mutated.
    public struct ExcludedSite: Sendable, Equatable {
        public let site: Mutation
        public let reason: String
    }

    /// Parses and folds standard Swift operators, rejecting malformed or excessively nested input.
    /// - Note: Syntax discovery only; the schema build proves each candidate compiles.
    /// - Complexity: O(*n*) in the syntax nodes of `source`.
    public static func discover(
        in source: String,
        path: String,
        operators: Set<MutationOperator> = MutationOperator.defaults,
        aridCalls: [String] = [],
        excludeDeclarations: [String] = [],
        oracle: TypeOracle = .empty()
    ) throws -> Discovery {
        let parsed = Parser.parse(source: source)
        guard !parsed.hasError, !SyntaxDepth.exceeds(parsed, limit: 256) else {
            throw LitmusFailure("\(path): invalid syntax or syntax nesting exceeds 256")
        }
        let tree = try OperatorTable.standardOperators.foldAll(parsed)
        let context = SiteContext(
            path: path,
            fingerprint: Digest.sha256(Array(source.utf8)),
            converter: SourceLocationConverter(fileName: path, tree: tree),
            anchors: Anchors(fileText: tree.description),
            operators: operators,
            aridCalls: aridCalls,
            excludeDeclarations: excludeDeclarations,
            oracle: oracle
        )
        let visitor = Sites(context)
        visitor.walk(tree)
        return Discovery(
            sites: ordered(withoutEquivalentNegations(visitor.sites)),
            excluded: visitor.excluded,
            skipped: visitor.skipped
        )
    }

    /// The schematisable sites of one file, in source order.
    public static func mutations(
        in source: String,
        path: String,
        operators: Set<MutationOperator> = MutationOperator.defaults,
        aridCalls: [String] = [],
        excludeDeclarations: [String] = [],
        oracle: TypeOracle = .empty()
    ) throws -> [Mutation] {
        try discover(
            in: source,
            path: path,
            operators: operators,
            aridCalls: aridCalls,
            excludeDeclarations: excludeDeclarations,
            oracle: oracle
        ).sites
    }

    /// Drops `!(c)` mutants (`swap-ternary`, `negate-condition`) of a comparison `c` that `replace-relational`
    /// already mutates: its replacements include the comparison's complement (`==` to `!=`, `<` to `>=`, …), which
    /// behaves exactly as `!(c)`, so the second mutant would count one weakness twice.
    static func withoutEquivalentNegations(_ sites: [Mutation]) -> [Mutation] {
        let relational = Set(sites.filter { $0.operatorID == .replaceRelational }.map { [$0.start, $0.end] })
        guard !relational.isEmpty else { return sites }
        return sites.filter { site in
            guard site.operatorID == .swapTernary || site.operatorID == .negateCondition else { return true }
            return !(relational.contains([site.start, site.end]) && site.replacement == "!(\(site.original))")
        }
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
        packagePath: String? = nil,
        jobs: Int = 4,
        scope: ChangeScope? = nil,
        operators: Set<MutationOperator> = MutationOperator.defaults,
        aridCalls: [String] = [],
        excludeDeclarations: [String] = [],
        indexedRoot: String? = nil,
        indexStorePath: String? = nil
    ) async throws -> MutationPlan {
        let root = SourcePath.canonical(root)
        let storeRoot = indexedRoot.map(SourcePath.canonical) ?? root
        guard FileManager.default.fileExists(atPath: root) else { throw LitmusFailure("root does not exist: \(root)") }
        let filter = PathFilter(exclude + ["Package.swift", "Dangerfile.swift", "**/Plugins/**"], root: root)
        if let scope {
            return try await plan(
                root: root,
                filter: filter,
                include: include,
                packagePath: packagePath,
                jobs: jobs,
                scope: scope,
                operators: operators,
                aridCalls: aridCalls,
                excludeDeclarations: excludeDeclarations,
                indexedRoot: storeRoot,
                indexStorePath: indexStorePath
            )
        }
        let discovery = SourceDiscovery.discover(under: root, isExcluded: filter.excludes)
        guard !discovery.files.isEmpty else { throw LitmusFailure("no Swift source files under \(root)") }
        var discovered = discovery.files.filter { path in
            packagePath.map { path.hasPrefix(root + "/" + $0 + "/") } ?? true
        }
        if !include.isEmpty {
            let wanted = PathFilter(include, root: root)
            discovered = discovered.filter { wanted.excludes($0) }
            guard !discovered.isEmpty else {
                throw LitmusFailure("no Swift source file matches the include list: \(include.joined(separator: ", "))")
            }
        }
        let classification = ProjectLayout.discover(paths: [root]).map(ProjectClassification.load) ?? .conventionsOnly
        let oracle = try await openOracleIfNeeded(
            operators: operators,
            indexedRoot: storeRoot,
            root: root,
            discoveredPaths: discovered,
            explicitStorePath: indexStorePath
        )
        let files = try await mapConcurrently(discovered, limit: min(max(jobs, 1), 16)) { path in
            try Task.checkCancellation()
            return await LargeStack.run {
                planFile(
                    path: path,
                    root: root,
                    classification: classification,
                    operators: operators,
                    aridCalls: aridCalls,
                    excludeDeclarations: excludeDeclarations,
                    oracle: oracle
                )
            }
        }
        let issues =
            discovery.unreadableDirectories.map {
                PlanNote(path: $0, reason: "directory could not be read", isDegraded: true)
            }
            + classification.unknownProjects.map {
                PlanNote(path: $0.path, reason: "classification uses conventions: \($0.reason)")
            }
        var result = MutationPlan(
            root: root,
            analyzedFiles: files.count,
            mutations: files.flatMap(\.mutations),
            suppressed: files.flatMap(\.suppressed),
            notes: issues + files.flatMap(\.notes)
        )
        result.skipped = mergeSkipped(files.compactMap(\.skipped))
        return result
    }
}
