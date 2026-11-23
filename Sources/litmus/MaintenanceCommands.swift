import AnalyzerCLI
import ArgumentParser
import Foundation
import LitmusCore
import ReportSupport

struct Merge: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Merge the run directories of every shard of one run (--shard k/n) into one artifact."
    )
    @Argument(help: "The shards' run directories.") var runs: [String]
    @Option(help: "New directory for the merged run.json and run.pb.") var output: String
    mutating func run() async throws {
        do {
            let merged = try ShardMerge.merge(runDirectories: runs, output: output)
            stderr("litmus: \(merged.results.count) mutants from \(runs.count) shards; evidence at \(output)/run.json")
        } catch { try fail(error, code: .usage) }
    }
}

struct Restore: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Restore the files an interrupted in-place run left rewritten (from <root>/.litmus/restore)."
    )
    @Argument(help: "Subject root of the in-place run.") var root: String = "."
    mutating func run() async throws {
        let root = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
        do {
            let restored = try InPlaceRestore.restore(root: root)
            stderr("litmus: \(restored) file(s) restored in \(root)")
        } catch { try fail(error, code: .internalFailure) }
    }
}

struct Check: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract:
            "Check package paths, discoverable Xcode test plans, or an existing .xctestrun without building or executing project code."
    )
    @Argument(help: "Repository/snapshot root containing local dependencies.") var root: String = "."
    @OptionGroup var build: BuildSelectionOptions
    @Option(help: "Existing .xctestrun artifact to inspect for runnable test bundles.") var xctestrun: String?

    func run() throws {
        do {
            let root = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
            let driver = try build.driver(root: root)
            try driver.validatePackage(workspace: root)
            try XcodeTestConfiguration.preflight(driver: driver, workspace: root)
            if let xctestrun {
                let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: xctestrun))
                defer { try? handle.close() }
                let bytes = Array(try handle.read(upToCount: (4 << 20) + 1) ?? Data())
                guard bytes.count <= 4 << 20 else { throw ValidationError("xctestrun exceeds 4 MiB") }
                try XcodeTestConfiguration.validateTestRun(bytes, path: xctestrun)
            }
            print(
                "Configuration checks passed. Generated schemes and actual test discovery still require Xcode build-for-testing; this check does not establish that tests run."
            )
        } catch { try fail(error, code: .badConfiguration) }
    }
}
