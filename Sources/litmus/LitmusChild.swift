import Foundation
import LitmusCore

/// This executable run as a child process (`litmus mcp`, `litmus watch`): the same validation, consent flags and exit
/// codes as a person's command line, and a crash that ends only the child.
enum LitmusChild {
    static var executable: String {
        let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// `arguments`, with stdout and stderr captured.
    static func run(_ arguments: [String], timeout: Int) async throws -> ProcessOutput {
        try await BoundedExecutor().execute(
            ToolCommand(executable: executable, arguments: arguments),
            directory: FileManager.default.currentDirectoryPath,
            environment: [:],
            timeout: timeout
        )
    }

    /// A per-subject cache directory (`~/Library/Caches/litmus/<kind>/<digest of root>`), created.
    static func cache(_ kind: String, root: String) throws -> String {
        let base =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.path
            ?? NSTemporaryDirectory()
        let directory = "\(base)/litmus/\(kind)/\(Digest.sha256(Array(root.utf8)).prefix(16))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A fresh run directory under `cache`, named by time so the newest sorts last.
    static func runDirectory(in cache: String) -> String {
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        return "\(cache)/runs/\(stamp)-\(UUID().uuidString.prefix(6))"
    }

    /// `run`'s arguments for warm repeated runs: a persistent build directory and result store per subject.
    static func warmRunArguments(root: String, cache: String, output: String) -> [String] {
        ["run", root, "--output", output, "--result-store", cache + "/store", "--build-directory", cache + "/build"]
    }
}
