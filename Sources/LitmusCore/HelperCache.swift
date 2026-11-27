internal import AemiIO
internal import Foundation
internal import IndexStoreSupport

/// A helper program Litmus compiles from embedded source once per toolchain: kept in the user's cache
/// (`~/Library/Caches/litmus/<name>/<key>`, else `<directory>/litmus-<name>`) and reused while it is trusted.
enum HelperCache {
    /// The machine's architecture, as compilers and target triples spell it.
    static var architecture: String {
        #if arch(arm64)
            "arm64"
        #else
            "x86_64"
        #endif
    }

    /// The helper's path, compiled when it is missing: `arguments(source, output, architecture)` are `xcrun`'s.
    /// - Parameters:
    ///   - compiler: the compiler's `--version`; the helper is keyed by its source, the compiler and the architecture.
    ///   - label: what failure messages call it; the build log is `logs/<name>-build.log`.
    static func helper(
        name: String,
        label: String,
        source text: String,
        compiler: String,
        directory: String,
        executor: some ProcessExecutor,
        logs: String,
        arguments: (_ source: String, _ output: String, _ architecture: String) -> [String]
    ) async throws -> String {
        let key = text + "\u{0}" + compiler + "\u{0}" + architecture
        let cacheRoot: String = {
            if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.path {
                let candidate = caches + "/litmus/" + name
                if (try? FileManager.default.createDirectory(atPath: candidate, withIntermediateDirectories: true))
                    != nil
                {
                    return candidate
                }
            }
            return directory + "/litmus-" + name
        }()
        let home = cacheRoot + "/" + Digest.sha256(Array(key.utf8)).prefix(24)
        let helper = home + "/helper"
        if FileManager.default.isExecutableFile(atPath: helper), BinaryTrustChecker.isTrusted(at: helper) {
            return helper
        }
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let partial = helper + ".partial-" + UUID().uuidString.prefix(8)
        let source = home + "/main-" + UUID().uuidString.prefix(8) + ".swift"
        defer {
            try? FileManager.default.removeItem(atPath: source)
            try? FileManager.default.removeItem(atPath: partial)
        }
        try AtomicFile.replace(at: source, with: Array(text.utf8), durability: .none)
        let output = try await executor.execute(
            ToolCommand(executable: "/usr/bin/xcrun", arguments: arguments(source, partial, architecture)),
            directory: home,
            environment: subjectEnvironment(nil),
            timeout: 600
        )
        try writeLog(output, path: logs + "/\(name)-build.log")
        guard output.exitStatus == 0, !output.timedOut else {
            throw LitmusFailure("the \(label) did not build (logs/\(name)-build.log)")
        }
        // Another run may have published it meanwhile: either copy is the same program.
        if !FileManager.default.isExecutableFile(atPath: helper) {
            try? FileManager.default.moveItem(atPath: partial, toPath: helper)
        }
        guard FileManager.default.isExecutableFile(atPath: helper) else {
            throw LitmusFailure("the \(label) could not be published at \(helper)")
        }
        return helper
    }
}
