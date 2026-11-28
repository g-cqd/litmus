import ArgumentParser
import Foundation
import LitmusCore

/// `litmus watch`: reruns what the working tree's changes reach each time a Swift file is saved. Each pass is
/// `litmus run --diff-base <base> --include-test-changes` in the background, with a persistent build directory and
/// result store per subject, so only the edited code's mutants build and run again; the pass reports which verdicts
/// changed since the previous one.
struct Watch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Rerun the mutants of the working tree's changes whenever a Swift file is saved.",
        discussion: "Pass `litmus run` arguments after `--`, such as `-- --trust-project --scheme App`."
    )

    @Argument(help: "Subject root.") var root: String = "."
    @Option(help: "Mutate what changed since this git revision.") var base: String = "HEAD"
    @Option(help: "Seconds between checks for saved files.") var interval: Int = 1
    @Option(help: "Stop after this many passes (0: until interrupted).") var passes: Int = 0
    @Argument(parsing: .postTerminator, help: "More `litmus run` arguments.") var runArguments: [String] = []

    mutating func run() async throws {
        guard (1...60).contains(interval) else { throw ValidationError("interval must be 1...60 seconds") }
        let root = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
        let cache = try LitmusChild.cache("watch", root: root)
        var stamp = Self.sources(root)
        var previous: [String: Verdict] = [:]
        var count = 0
        while passes == 0 || count < passes {
            count += 1
            previous = try await pass(root: root, cache: cache, previous: previous)
            guard passes == 0 || count < passes else { break }
            stderr("litmus watch: waiting for a saved Swift file in \(root)")
            while true {
                try await Task.sleep(for: .seconds(interval))
                let now = Self.sources(root)
                guard now != stamp else { continue }
                // Saves often come in bursts (format on save, several files): wait until one interval passes quietly.
                try await Task.sleep(for: .seconds(interval))
                stamp = Self.sources(root)
                break
            }
        }
    }

    /// One run over the current changes; returns every verdict it knows, for the next pass to compare.
    func pass(root: String, cache: String, previous: [String: Verdict]) async throws -> [String: Verdict] {
        let output = LitmusChild.runDirectory(in: cache)
        let arguments =
            LitmusChild.warmRunArguments(root: root, cache: cache, output: output)
            + ["--diff-base", base, "--include-test-changes", "--background"] + runArguments
        let process = Process()
        process.executableURL = URL(fileURLWithPath: LitmusChild.executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        // The process says when it ends: no thread waits for it.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        guard let artifact = try? ArtifactCodec.read(RunArtifact.self, path: output + "/run.json") else {
            stderr("litmus watch: the pass ended (exit \(process.terminationStatus)) without a run artifact")
            return previous
        }
        var current = previous
        for result in artifact.results {
            let mutation = result.mutation
            if let before = previous[mutation.id], before != result.verdict {
                stderr(
                    "  \(mutation.path):\(mutation.line) \(mutation.operatorID.rawValue): \(before.rawValue) → \(result.verdict.rawValue)"
                )
            }
            current[mutation.id] = result.verdict
        }
        let open = artifact.results.filter { $0.verdict == .survived || $0.verdict == .noCoverage }
        stderr("litmus watch: \(artifact.results.count) mutant(s), \(open.count) undetected; evidence at \(output)")
        for result in open.prefix(20) {
            stderr(
                "  \(result.verdict.rawValue): \(result.mutation.path):\(result.mutation.line) \(result.mutation.operatorID.rawValue)"
            )
        }
        return current
    }

    /// Each Swift file under `root` with its modification time and size, outside build and VCS directories.
    static func sources(_ root: String) -> [String: [Double]] {
        var found: [String: [Double]] = [:]
        let skipped: Set<String> = [".build", ".git", "DerivedData", ".swiftpm", "node_modules"]
        guard let walker = FileManager.default.enumerator(atPath: root) else { return found }
        while let path = walker.nextObject() as? String {
            if skipped.contains(URL(fileURLWithPath: path).lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            guard path.hasSuffix(".swift"),
                let attributes = try? FileManager.default.attributesOfItem(atPath: root + "/" + path),
                let date = attributes[.modificationDate] as? Date
            else { continue }
            found[path] = [date.timeIntervalSince1970, Double((attributes[.size] as? Int) ?? 0)]
        }
        return found
    }
}
