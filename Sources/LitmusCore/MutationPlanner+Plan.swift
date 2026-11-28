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

extension MutationPlanner {
    /// The plan of the changed Swift files only: no directory walk, so a change touching no Swift file costs nothing.
    static func openOracleIfNeeded(
        operators: Set<MutationOperator>,
        indexedRoot: String,
        root: String,
        discoveredPaths: [String],
        explicitStorePath: String?
    ) async throws -> TypeOracle {
        guard operators.contains(where: \.usesTypeOracle) || explicitStorePath != nil else {
            return .empty(root: indexedRoot)
        }
        let relatives = discoveredPaths.compactMap { path -> String? in
            guard path.hasPrefix(root + "/") else { return nil }
            return String(path.dropFirst(root.count + 1))
        }
        return try await TypeOracle.open(
            indexedRoot: indexedRoot,
            analyzedRelativePaths: relatives,
            explicitStorePath: explicitStorePath
        )
    }

    static func plan(
        root: String,
        filter: PathFilter,
        include: [String],
        packagePath: String?,
        jobs: Int,
        scope: ChangeScope,
        operators: Set<MutationOperator>,
        aridCalls: [String],
        excludeDeclarations: [String],
        indexedRoot: String,
        indexStorePath: String?
    ) async throws -> MutationPlan {
        let wanted = include.isEmpty ? nil : PathFilter(include, root: root)
        var files: [String] = []
        var notes: [PlanNote] = []
        for relative in scope.plannedFiles.sorted() {
            let path = root + "/" + relative
            if packagePath.map({ !relative.hasPrefix($0 + "/") }) == true || filter.excludes(path)
                || wanted.map({ !$0.excludes(path) }) == true
            {
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
        let oracle = try await openOracleIfNeeded(
            operators: operators,
            indexedRoot: indexedRoot,
            root: root,
            discoveredPaths: files,
            explicitStorePath: indexStorePath
        )
        let planned = try await mapConcurrently(files, limit: min(max(jobs, 1), 16)) { path in
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
        // A change to a comment or blank line inside a multi-line mutant (a comment in a closure body) reaches no site.
        var codeLines: [String: Set<Int>] = [:]
        for path in files { codeLines[String(path.dropFirst(root.count + 1))] = Self.codeLines(of: path) }
        var ranked: [(priority: Int, mutation: Mutation)] = []
        for mutation in planned.flatMap(\.mutations) {
            if let priority = scope.priority(of: mutation, codeLines: codeLines) { ranked.append((priority, mutation)) }
        }
        ranked.sort {
            ($0.priority, $0.mutation.path, $0.mutation.start, $0.mutation.id) < (
                $1.priority, $1.mutation.path, $1.mutation.start, $1.mutation.id
            )
        }
        if let testDriven = scope.testDriven {
            notes.append(
                PlanNote(
                    path: testDriven.testFiles.joined(separator: ", "),
                    reason: "test change: \(testDriven.wholeFiles.count) production file(s) by covering test target, "
                        + "\(testDriven.mutants.count) mutant(s) by per-test reach of "
                        + "\(testDriven.reachedTests.count) changed test(s)"
                )
            )
        }
        var plan = MutationPlan(
            root: root,
            analyzedFiles: planned.count,
            mutations: ranked.map(\.mutation),
            suppressed: planned.flatMap(\.suppressed).filter { scope.priority(of: $0, codeLines: codeLines) != nil },
            notes: notes + planned.flatMap(\.notes)
        )
        plan.skipped = mergeSkipped(planned.compactMap(\.skipped))
        plan.scope = PlanScope(
            source: scope.source,
            digest: scope.digest,
            breadth: scope.breadth,
            changedFiles: scope.changed.files.count,
            changedLines: scope.changed.lineCount,
            swiftFiles: scope.swiftFiles.count,
            onChangedLines: ranked.filter { $0.priority == 0 }.map(\.mutation.id)
        )
        plan.scope?.testDriven = scope.testDriven
        return plan
    }

    static func mergeSkipped(_ parts: [[String: Int]]) -> [String: Int]? {
        var totals: [String: Int] = [:]
        for part in parts {
            for (reason, count) in part where count > 0 { totals[reason, default: 0] += count }
        }
        return totals.isEmpty ? nil : totals
    }
}
