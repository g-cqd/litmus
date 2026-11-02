/// Structured test evidence, independent of a build process's exit code.
public struct TestCounts: Codable, Sendable, Equatable {
    public let passed: Int
    public let failed: Int
    public let skipped: Int
    public init(passed: Int, failed: Int, skipped: Int) { self.passed = passed; self.failed = failed; self.skipped = skipped }
}
/// Outcomes kept separate so infrastructure errors cannot inflate a mutation score.
public enum Verdict: String, Codable, Sendable {
    case killed, survived, timeout, invalid, infrastructureError, notRun
    public static func classify(exitStatus: Int32, tests: TestCounts) -> Self { .survived }
}
/// An executable and its argv; never evaluated by a shell.
public struct ToolCommand: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]
}
/// Chooses SwiftPM for host packages, or Xcode for projects, workspaces and simulator packages.
public struct BuildDriver: Sendable {
    public init(root: String, container: String? = nil, scheme: String?, destination: String?) throws {}
    public func buildCommand(workspace: String, artifacts: String) -> ToolCommand { .init(executable: "", arguments: []) }
}
/// Versioned protobuf container for bounded machine artifacts.
public enum ArtifactWire {
    public static func encode(_ json: [UInt8]) -> [UInt8] { json }
    public static func decode(_ bytes: [UInt8]) throws -> [UInt8] { bytes }
}
