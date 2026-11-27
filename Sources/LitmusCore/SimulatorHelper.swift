internal import Foundation
internal import IndexStoreSupport

/// Builds the simulator test helper once per toolchain into the build directory (kept across runs with a
/// persistent workspace or `--build-directory`).
enum SimulatorHelper {
    struct Built: Sendable {
        let helper: String
        let simctl: String
        let frameworks: String
        let libraries: String
        let platforms: String
    }

    static func build(into directory: String, executor: some ProcessExecutor, logs: String) async throws -> Built {
        func query(_ arguments: [String]) async throws -> String {
            let output = try await executor.execute(
                ToolCommand(executable: "/usr/bin/xcrun", arguments: arguments),
                directory: directory,
                environment: subjectEnvironment(nil),
                timeout: 120
            )
            guard output.exitStatus == 0, !output.truncated else {
                throw LitmusFailure("`xcrun \(arguments.joined(separator: " "))` failed")
            }
            return String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let platform = try await query(["--sdk", "iphonesimulator", "--show-sdk-platform-path"])
        let sdk = try await query(["--sdk", "iphonesimulator", "--show-sdk-path"])
        let compiler = try await query(["--sdk", "iphonesimulator", "swiftc", "--version"])
        let resolvedSimctl = try? await query(["--find", "simctl"])
        let simctl = resolvedSimctl.flatMap { BinaryTrustChecker.isTrusted(at: $0) ? $0 : nil } ?? "/usr/bin/xcrun"
        let frameworks = platform + "/Developer/Library/Frameworks"
        let helper = try await HelperCache.helper(
            name: "simulator-helper",
            label: "simulator test helper",
            source: simulatorHelperSource,
            compiler: compiler,
            directory: directory,
            executor: executor,
            logs: logs
        ) { source, output, architecture in
            [
                "--sdk", "iphonesimulator", "swiftc", "-parse-as-library", "-swift-version", "5", "-O",
                "-target", "\(architecture)-apple-ios17.0-simulator", "-sdk", sdk, source,
                "-o", output, "-F", frameworks, "-Xlinker", "-framework", "-Xlinker", "XCTest",
                "-Xlinker", "-framework", "-Xlinker", "Testing", "-Xlinker", "-rpath", "-Xlinker", frameworks,
            ]
        }
        return Built(
            helper: helper,
            simctl: simctl,
            frameworks: frameworks,
            libraries: platform + "/Developer/usr/lib",
            platforms: (platform as NSString).deletingLastPathComponent
        )
    }
}
