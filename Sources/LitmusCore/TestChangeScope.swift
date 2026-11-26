internal import Foundation
internal import ProjectModel
internal import SourceCorpus
internal import SwiftParser
internal import SwiftSyntax

/// The production code a change to tests can affect (`--include-test-changes`): a pull request that deletes or weakens
/// a test, or adds one, plans the mutants those tests decide instead of none.
///
/// Per changed test file, the narrowest sound answer available:
/// 1. **Reach** (`--reach-from` with per-test reach): the mutants that the changed Swift Testing tests reached in that
///    run, when every changed line lies inside a test that run knew.
/// 2. **Targets**: otherwise every site of every production file that the file's test targets cover
///    (analyzerkit's `testTargets(covering:)`); every production file when no target claims the test file.
public struct TestDrivenScope: Codable, Sendable, Equatable {
    /// The changed and deleted test files, relative to the root.
    public let testFiles: [String]
    /// Production files every site of which is in scope (targets tier).
    public let wholeFiles: [String]
    /// Mutants in scope one by one (reach tier), and the files holding them.
    public let mutants: [String]
    public let mutantFiles: [String]
    /// The changed tests resolved through reach, as the reach artifact names them.
    public let reachedTests: [String]
}

enum TestChangeScope {
    /// `scope` with the production code its test changes can affect, or `scope` itself when it changes no test file.
    /// - Parameter reach: a run whose per-test reach maps tests to mutants (`--reach-from`); nil uses targets only.
    static func resolve(_ scope: ChangeScope, root: String, reach: RunArtifact?) -> ChangeScope {
        let root = SourcePath.canonical(root)
        let classification = ProjectLayout.discover(paths: [root]).map(ProjectClassification.load) ?? .conventionsOnly
        func isTest(_ path: String) -> Bool {
            classification.classify(root + "/" + path).region.contains(.test) || TestConventions.isTestPath(path)
        }
        let changedTests = scope.swiftFiles.filter(isTest).sorted()
        let deletedTests = scope.changed.deleted.filter { $0.hasSuffix(".swift") && isTest($0) }.sorted()
        guard !changedTests.isEmpty || !deletedTests.isEmpty else { return scope }

        let byTest = reach.map(testsToMutants) ?? [:]
        let paths = Dictionary(
            (reach?.results ?? []).map { ($0.mutation.id, $0.mutation.path) },
            uniquingKeysWith: { first, _ in first }
        )
        var mutants: Set<String> = []
        var reachedTests: Set<String> = []
        var byTargets: [String] = deletedTests
        for path in changedTests {
            if let resolved = reached(path, root: root, scope: scope, byTest: byTest) {
                mutants.formUnion(resolved.mutants)
                reachedTests.formUnion(resolved.tests)
            } else {
                byTargets.append(path)
            }
        }
        let wholeFiles =
            byTargets.isEmpty ? [] : coveredFiles(by: byTargets, root: root, classification: classification)
        var result = scope
        result.testDriven = TestDrivenScope(
            testFiles: (changedTests + deletedTests).sorted(),
            wholeFiles: wholeFiles,
            mutants: mutants.sorted(),
            mutantFiles: Set(mutants.compactMap { paths[$0] }).sorted(),
            reachedTests: reachedTests.sorted()
        )
        return result
    }

    /// The tests and mutants the changed lines of `path` resolve to through reach; nil when any changed line is
    /// outside a known Swift Testing test (a helper, an XCTest case, a new test, a deletion-only hunk).
    private static func reached(
        _ path: String,
        root: String,
        scope: ChangeScope,
        byTest: [String: Set<String>]
    ) -> (tests: Set<String>, mutants: Set<String>)? {
        guard !byTest.isEmpty, let ranges = scope.changed.files[path], !ranges.isEmpty,
            let bytes = try? BoundedFileReader.read(path: root + "/" + path, cap: 8 << 20)
        else { return nil }
        let tree = Parser.parse(source: String(decoding: bytes, as: UTF8.self))
        let declared = TestDeclarationScanner.scan(tree, converter: SourceLocationConverter(fileName: path, tree: tree))
        var tests: Set<String> = []
        var mutants: Set<String> = []
        for range in ranges {
            let touched = declared.filter { $0.lines.overlaps(range) }
            // A changed line outside every test, or inside one the reach run does not know: not resolvable.
            guard !touched.isEmpty, touched.allSatisfy({ $0.framework == .swiftTesting }) else { return nil }
            let covered = touched.reduce(0) { $0 + $1.lines.clamped(to: range).count }
            guard covered == range.count else { return nil }
            for test in touched {
                let known = byTest.keys.filter { matches($0, test) }
                guard !known.isEmpty else { return nil }
                for id in known {
                    tests.insert(id)
                    mutants.formUnion(byTest[id] ?? [])
                }
            }
        }
        return (tests, mutants)
    }

    /// Whether the reach artifact's test identifier `id` names `test`.
    static func matches(_ id: String, _ test: TestDeclaration) -> Bool {
        if let suite = test.suite { return id.hasSuffix(suite + "/" + test.signature) }
        return id == test.signature || id.hasSuffix("." + test.signature) || id.hasSuffix("/" + test.signature)
    }

    /// Per test, the mutants it reached in `artifact`.
    private static func testsToMutants(_ artifact: RunArtifact) -> [String: Set<String>] {
        var map: [String: Set<String>] = [:]
        for (mutant, tests) in artifact.perTestReach ?? [:] {
            for test in tests { map[test, default: []].insert(mutant) }
        }
        return map
    }

    /// The production files the test targets owning `testFiles` cover; every production file when a test file has no
    /// known target.
    private static func coveredFiles(
        by testFiles: [String],
        root: String,
        classification: ProjectClassification
    ) -> [String] {
        var owners: Set<ProjectTarget> = []
        var unknown = false
        for path in testFiles {
            guard case .targets(let targets) = classification.classify(root + "/" + path).provenance,
                targets.contains(where: \.isTest)
            else {
                unknown = true
                continue
            }
            owners.formUnion(targets.filter(\.isTest))
        }
        let filter = PathFilter(["Package.swift", "**/Plugins/**"], root: root)
        let discovered = SourceDiscovery.discover(under: root, isExcluded: filter.excludes).files
        var files: [String] = []
        for absolute in discovered {
            guard classification.classify(absolute).region == .production else { continue }
            let relative = String(absolute.dropFirst(root.count + 1))
            if unknown || !owners.isDisjoint(with: classification.testTargets(covering: absolute)) {
                files.append(relative)
            }
        }
        return files.sorted()
    }
}
