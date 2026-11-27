internal import Foundation
internal import ProjectModel

/// What a mutant's verdict depends on, as one digest.
///
/// A verdict is reused only when its key matches, and the key holds everything that can change it under the
/// deterministic-test assumption the flaky probe enforces:
/// - the mutant's anchored identity, its text and replacement;
/// - every input of its package and of the local packages that package depends on (analyzerkit's
///   `packageClosure(containing:)`); the whole snapshot for an Xcode project or a layout it cannot read;
/// - the tool version, execution policy, toolchain, build driver, and every option that changes a verdict.
///
/// `--reuse declaration` (nightly only) replaces the closure by the mutant's declaration and its test targets' files:
/// it reuses across edits elsewhere in the module, at the price of soundness, and says so on every reused verdict.
public struct ReuseContext: Sendable {
    /// How much of the code a key covers.
    public enum Mode: String, Codable, Sendable {
        /// Every input that can change the verdict (default; the only mode a pull-request gate may use).
        case closure
        /// The declaration and the covering test targets only (Stryker-like); not sound, labelled as such.
        case declaration
    }

    let mode: Mode
    let context: String
    private let entries: [SnapshotEntry]
    private let wholeSnapshot: String
    private let closures: [String: String]
    private let testFiles: [String: String]

    /// - Parameters:
    ///   - root: the snapshot root, whose entries are `entries`.
    ///   - closureKnown: false for Xcode projects, whose app target the package layout does not describe.
    ///   - inPlace: the workspace is the subject itself, whose build can reach outside the root.
    init(
        mode: Mode,
        root: String,
        entries: [SnapshotEntry],
        wholeSnapshot: String,
        mutations: [Mutation],
        closureKnown: Bool,
        inPlace: Bool = false,
        context: ReuseContextInputs
    ) throws {
        self.mode = mode
        self.entries = entries
        self.wholeSnapshot = wholeSnapshot
        self.context = Digest.sha256(try ArtifactCodec.json(context))
        let layout = ProjectLayout.discover(paths: [root])
        let classification = layout.map(ProjectClassification.load)
        var closures: [String: String] = [:]
        var testFiles: [String: String] = [:]
        var outside: Set<String> = []
        var byClosure: [[String]: String] = [:]
        let sorted = entries.sorted { $0.path < $1.path }
        // With test-target selection, a mutant runs only the test targets covering its file: another target's test
        // files cannot change its verdict, so editing them keeps it reusable. A file no target claims still counts.
        let narrowsTests = mode == .closure && closureKnown && context.selectTestTargets
        let testOwners = narrowsTests ? Self.testOwners(sorted, root: root, classification: classification) : [:]
        /// The digest of the entries under `directories`, leaving out the test files of targets other than
        /// `covering` (nil keeps every test file).
        func digest(under directories: [String], covering: Set<ProjectTarget>? = nil) -> String {
            let cacheKey =
                directories + ["\u{0}"] + (covering.map { $0.map { "\($0.container)|\($0.name)" }.sorted() } ?? [])
            if let known = byClosure[cacheKey] { return known }
            let prefixes = directories.map { $0.isEmpty ? "" : $0 + "/" }
            var lines: [UInt8] = []
            for entry in sorted where prefixes.contains(where: { $0.isEmpty || entry.path.hasPrefix($0) }) {
                if let covering, let owners = testOwners[entry.path], owners.isDisjoint(with: covering) { continue }
                lines += Array("\(entry.path)\u{0}\(entry.sha256)\n".utf8)
            }
            let value = Digest.sha256(lines)
            byClosure[cacheKey] = value
            return value
        }
        for path in Set(mutations.map(\.path)) {
            let absolute = root + "/" + path
            var directories: [String]?
            let closure = closureKnown ? classification?.packageClosure(containing: absolute) : nil
            if let closure, closure.allSatisfy({ $0 == root || $0.hasPrefix(root + "/") }) {
                directories = closure.map { $0 == root ? "" : String($0.dropFirst(root.count + 1)) }
                let covering = classification.map { Set($0.testTargets(covering: absolute)) }
                closures[path] = digest(
                    under: directories ?? [],
                    covering: narrowsTests && covering?.isEmpty == false ? covering : nil
                )
            } else if inPlace || closure.map({ !$0.isEmpty }) == true {
                // A local dependency outside the root (an in-place run of one package of a repository), or, in place,
                // a closure that cannot be read: files the root's inventory does not hold could change the verdict
                // unnoticed. Such a mutant is never reused. (A copy cannot build what is outside its root.)
                closures[path] = "unreusable-" + UUID().uuidString
                outside.insert(path)
            } else {
                closures[path] = wholeSnapshot
            }
            if mode == .declaration {
                // Every file in a test directory of the closure (of the snapshot when the closure is unknown): a test
                // added or changed anywhere in the package invalidates; a change to the code it calls does not.
                let scope = directories ?? [""]
                let prefixes = scope.map { $0.isEmpty ? "" : $0 + "/" }
                let tests = Self.testDirectories(
                    sorted.filter { entry in prefixes.contains { $0.isEmpty || entry.path.hasPrefix($0) } }
                )
                testFiles[path] = digest(under: tests)
            }
        }
        self.closures = closures
        self.testFiles = testFiles
        self.outsideRoot = outside
    }

    /// The test targets owning each test file among `entries`: files only test targets compile.
    private static func testOwners(
        _ entries: [SnapshotEntry],
        root: String,
        classification: ProjectClassification?
    ) -> [String: Set<ProjectTarget>] {
        guard let classification else { return [:] }
        var owners: [String: Set<ProjectTarget>] = [:]
        for entry in entries {
            guard case .targets(let targets) = classification.classify(root + "/" + entry.path).provenance,
                !targets.isEmpty, targets.allSatisfy(\.isTest)
            else { continue }
            owners[entry.path] = Set(targets)
        }
        return owners
    }

    /// The files whose package depends on a local package outside the root: their mutants are never reused.
    let outsideRoot: Set<String>

    /// The directories named `Tests` or ending in `Tests` among `entries`' paths, outermost first.
    private static func testDirectories(_ entries: [SnapshotEntry]) -> [String] {
        var directories: Set<String> = []
        for entry in entries {
            let parts = entry.path.split(separator: "/")
            if let index = parts.firstIndex(where: { $0 == "Tests" || $0.hasSuffix("Tests") }) {
                directories.insert(parts[...index].joined(separator: "/"))
            }
        }
        return directories.sorted()
    }

    /// The key of `mutation`.
    public func key(_ mutation: Mutation) -> String {
        let code: String
        switch mode {
        case .closure: code = closures[mutation.path] ?? wholeSnapshot
        case .declaration where outsideRoot.contains(mutation.path):
            code = closures[mutation.path] ?? wholeSnapshot
        case .declaration:
            code = (mutation.declarationDigest ?? wholeSnapshot) + "|" + (testFiles[mutation.path] ?? wholeSnapshot)
        }
        let fields = [
            "litmus-reuse/v1", mode.rawValue, context, mutation.id, mutation.path, mutation.operatorID.rawValue,
            mutation.original, mutation.replacement, code,
        ]
        return Digest.sha256(Array(fields.joined(separator: "\u{0}").utf8))
    }
}

/// What the run's options and environment contribute to a key: anything that can change a verdict.
struct ReuseContextInputs: Encodable {
    let toolVersion: String
    let executionPolicy: String
    let toolchain: String
    let driver: BuildDriver
    let harness: String
    let failFast: Bool
    let killConfirmation: String
    let memoryLimitMiB: Int
    let timeoutCap: Int
    let timeoutFactor: Int
    let minimumTimeout: Int
    let baselineRepetitions: Int
    let suiteWidth: Int?
    let selectTestTargets: Bool
    let background: Bool
    let excluded: [String]
}
