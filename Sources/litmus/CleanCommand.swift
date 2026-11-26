import AnalyzerCLI
import ArgumentParser
import Foundation
import LitmusCore

struct Clean: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract:
            "Remove what interrupted or finished runs left: orphaned pool simulators, and the workspaces and build products of run directories."
    )
    @Flag(help: "Delete simulators of dead runs' pools (default when no run directory is given).") var simulators =
        false
    @Option(
        name: .customLong("run"),
        help: "A finished run directory whose workspace and build products to remove (repeatable)."
    )
    var runs: [String] = []
    @Flag(help: "Say what would be removed, remove nothing.") var dryRun = false

    mutating func run() async throws {
        var cleaned: [Maintenance.Cleaned] = []
        if simulators || runs.isEmpty {
            cleaned.append(
                await Maintenance.cleanSimulators(
                    executor: BoundedExecutor(),
                    directory: FileManager.default.currentDirectoryPath,
                    dryRun: dryRun
                )
            )
        }
        if !runs.isEmpty {
            let paths = runs.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }
            cleaned.append(Maintenance.cleanRuns(paths, dryRun: dryRun))
        }
        let simulatorCount = cleaned.reduce(0) { $0 + $1.simulators.count }
        let directories = cleaned.flatMap(\.directories)
        let bytes = cleaned.reduce(Int64(0)) { $0 + $1.freedBytes }
        for name in cleaned.flatMap(\.simulators) {
            stderr("litmus: \(dryRun ? "would delete" : "deleted") simulator \(name)")
        }
        for path in directories { stderr("litmus: \(dryRun ? "would remove" : "removed") \(path)") }
        let freed = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        stderr(
            "litmus: \(dryRun ? "would delete" : "deleted") \(simulatorCount) orphaned simulator(s), "
                + "\(directories.count) run director\(directories.count == 1 ? "y" : "ies"); \(dryRun ? "would free" : "freed") \(freed)"
        )
        let failures = cleaned.flatMap(\.failures)
        for failure in failures { stderr("litmus: \(failure)") }
        if !failures.isEmpty { throw ExitCode(ExitStatus.internalFailure.rawValue) }
    }
}
