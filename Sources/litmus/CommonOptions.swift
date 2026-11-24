import AnalyzerCLI
import ArgumentParser
import Foundation
import LitmusCore
import ReportSupport

struct SubjectOptions: ParsableArguments {
    @Argument(
        help:
            "Subject root containing all local dependencies; copied by default (in-place mode deliberately rewrites and restores it)."
    ) var root: String = "."
    @Option(help: "Configuration file: exclude, and include in .litmus.json or the litmus section.") var config: String?
    @Option(name: .customLong("exclude-path"), help: "Exclude a substring/glob from mutation discovery (repeatable).")
    var exclusions: [String] = []
    @Option(name: .customLong("only-path"), help: "Mutate only files matching a substring/glob (repeatable).")
    var inclusions: [String] = []
    @Option(
        help:
            "Operators to mutate, comma-separated rule ids (default: the stable tier). Known: negate-condition, swap-ternary, replace-logical, replace-relational, flip-boolean, replace-arithmetic, remove-call."
    )
    var operators: String?
    @Option(
        help:
            "Operator tier to mutate: stable (default), standard (adds comparisons, booleans, arithmetic) or experimental (adds call removal)."
    )
    var operatorTier: String?
    /// The operators this run or plan mutates; `--operators` names them exactly, a tier includes every tier before it.
    func operatorSet() throws -> Set<MutationOperator> {
        do {
            if let operators {
                guard operatorTier == nil else {
                    throw ValidationError("--operators and --operator-tier are alternatives; give one")
                }
                return try MutationOperator.parse(operators)
            }
            guard let operatorTier else { return MutationOperator.defaults }
            guard let tier = OperatorTier(rawValue: operatorTier) else {
                throw ValidationError("operator tier must be stable, standard or experimental")
            }
            return MutationOperator.operators(upTo: tier)
        } catch let error as ValidationError {
            throw error
        } catch { try fail(error, code: .usage) }
    }
    var absoluteRoot: String { URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path }
    func excludes() throws -> [String] {
        do { return try LitmusConfiguration.load(root: absoluteRoot, explicit: config).exclude + exclusions } catch {
            try fail(error, code: .badConfiguration)
        }
    }
    func includes() throws -> [String] {
        do { return try LitmusConfiguration.load(root: absoluteRoot, explicit: config).include + inclusions } catch {
            try fail(error, code: .badConfiguration)
        }
    }
}

/// What a pull-request run mutates.
struct ChangeOptions: ParsableArguments {
    @Option(help: "Limit to the change in this unified diff (paths relative to --diff-root).") var diff: String?
    @Option(
        help:
            "Limit to the change from the merge base with this revision to the working tree (git; tracked files only)."
    )
    var diffBase: String?
    @Option(help: "Directory the --diff paths are relative to (default: the enclosing git work tree, else the root).")
    var diffRoot: String?
    @Option(help: "Leading path components to strip from --diff paths (default: detect git's a/ and b/).")
    var diffStrip: Int?
    @Option(help: "lines: sites on changed lines; files: every site of changed files, changed lines first.")
    var diffScope: String = "lines"

    func scope(root: String) async throws -> ChangeScope? {
        guard diff == nil || diffBase == nil else { throw ValidationError("--diff and --diff-base are exclusive") }
        guard let breadth = ChangeScope.Breadth(rawValue: diffScope) else {
            throw ValidationError("diff-scope must be lines or files")
        }
        if let diff {
            return try ChangeScope.load(
                diffFile: diff,
                root: root,
                diffRoot: diffRoot.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path },
                strip: diffStrip,
                breadth: breadth
            )
        }
        if let diffBase {
            return try await ChangeScope.fromGit(
                base: diffBase,
                root: root,
                breadth: breadth,
                executor: BoundedExecutor()
            )
        }
        return nil
    }
}

struct BuildSelectionOptions: ParsableArguments {
    @Option(help: "Relative .xcodeproj/.xcworkspace inside root. Omit for Swift packages.") var project: String?
    @Option(
        help:
            "Package directory relative to root; snapshot the containing root and execute inside this package. Cannot combine with --project."
    ) var packagePath: String?
    @Option(help: "Xcode scheme (required for iOS packages/projects).") var scheme: String?
    @Option(help: "Explicit Xcode test plan configured by the scheme; requires --scheme.") var testPlan: String?
    @Option(help: "Xcode destination (supply an existing simulator ID for reproducibility).") var destination: String?

    func driver(root: String) throws -> BuildDriver {
        guard testPlan == nil || scheme != nil else { throw ValidationError("--test-plan requires --scheme") }
        var driver = try BuildDriver(
            root: root,
            container: project,
            packagePath: packagePath,
            scheme: scheme,
            destination: destination
        )
        driver.testPlan = testPlan
        return driver
    }
}

func stderr(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
func fail(_ error: any Error, code: ExitStatus) throws -> Never {
    stderr("litmus: error: \(error)")
    throw ExitCode(code.rawValue)
}

/// Numeric limits on the mutation score (`--minimum-score`, `--maximum-score-drop`).
struct GateOptions: ParsableArguments {
    @Option(help: "Fail when the mutation score is below this percentage (0...100).") var minimumScore: Double?
    @Option(help: "Fail when the score fell by more than this many percentage points from --baseline-run.")
    var maximumScoreDrop: Double?
    @Option(help: "An earlier run (.json or .pb) the score drop is measured against; both must be whole-subject runs.")
    var baselineRun: String?

    func validate() throws {
        for (name, value) in [("--minimum-score", minimumScore), ("--maximum-score-drop", maximumScoreDrop)] {
            if let value, !(0...100).contains(value) { throw ValidationError("\(name) must be between 0 and 100") }
        }
        if maximumScoreDrop != nil, baselineRun == nil {
            throw ValidationError("--maximum-score-drop needs --baseline-run")
        }
    }

    /// The gate, with its baseline run read.
    func gate() throws -> QualityGate {
        var baseline: RunArtifact?
        if let baselineRun {
            do { baseline = try ArtifactCodec.read(RunArtifact.self, path: baselineRun) } catch {
                try fail(error, code: .badConfiguration)
            }
        }
        return QualityGate(minimumScore: minimumScore, maximumScoreDrop: maximumScoreDrop, baseline: baseline)
    }

    /// Prints why the run fails the gate; true when it does.
    func fails(_ artifact: RunArtifact) throws -> Bool {
        let failures = try gate().failures(for: artifact)
        for failure in failures { stderr("litmus: gate: \(failure)") }
        return !failures.isEmpty
    }
}
