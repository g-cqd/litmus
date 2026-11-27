import Foundation

@testable import LitmusCore

/// Runs a tool and waits for it without holding a thread of Swift's cooperative pool. A test that blocks on a child
/// (`waitUntilExit`, `readDataToEndOfFile`) holds one of the pool's threads (three on a CI runner), and the executor
/// tasks of concurrent tests, such as a monitor's stop, then run late.
func runTool(
    _ executable: String,
    _ arguments: [String],
    directory: String = "/",
    environment: [String: String] = [:],
    timeout: Int = 600
) async throws -> (status: Int32, output: String) {
    let result = try await BoundedExecutor().execute(
        ToolCommand(executable: executable, arguments: arguments),
        directory: directory,
        environment: environment,
        timeout: timeout
    )
    let text = String(decoding: result.stdout + result.stderr, as: UTF8.self)
    return (result.timedOut ? -1 : result.exitStatus, text)
}
