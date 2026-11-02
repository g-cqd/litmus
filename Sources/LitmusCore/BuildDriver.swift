internal import Foundation
internal import SourceCorpus

/// Chooses SwiftPM for host packages and Xcode for simulator packages, projects and workspaces.
public struct BuildDriver: Codable, Sendable, Equatable {
    public let root: String
    public let container: String?
    public let scheme: String?
    public let destination: String?
    public var usesXcode: Bool { scheme != nil }

    /// Container paths must remain inside the isolated root. Scheme/destination are required together.
    /// A nil container with a scheme means an Xcode-opened Swift package, not a host `swift test` run.
    public init(root: String, container: String? = nil, scheme: String?, destination: String?) throws {
        guard (scheme == nil) == (destination == nil) else { throw LitmusFailure("scheme and destination must be supplied together") }
        if let container {
            guard scheme != nil, !container.hasPrefix("/"),
                !container.split(separator: "/").contains(".."),
                container.hasSuffix(".xcodeproj") || container.hasSuffix(".xcworkspace")
            else { throw LitmusFailure("Xcode container must be a relative project/workspace path inside root; supply scheme and destination") }
        }
        self.root = root; self.container = container; self.scheme = scheme; self.destination = destination
    }

    /// A bounded build-for-testing command. Artifacts must be outside the original source tree.
    public func buildCommand(workspace: String, artifacts: String) -> ToolCommand {
        if usesXcode {
            return ToolCommand(executable: "/usr/bin/xcrun", arguments: ["xcodebuild", "build-for-testing"] + xcodeArguments + ["-derivedDataPath", artifacts + "/DerivedData", "-parallel-testing-enabled", "NO"])
        }
        return ToolCommand(executable: "/usr/bin/xcrun", arguments: ["swift", "build", "--package-path", workspace, "--scratch-path", artifacts + "/build", "--build-tests", "-j", "4"])
    }

    /// Runs the same entire selected suite for the baseline, every inactive schema and each active mutant.
    public func testCommand(workspace: String, artifacts: String, result: String, xctestrun: String? = nil) throws -> ToolCommand {
        if usesXcode {
            guard let destination, let xctestrun else { throw LitmusFailure("missing Xcode test artifact/destination") }
            return ToolCommand(executable: "/usr/bin/xcrun", arguments: ["xcodebuild", "test-without-building", "-xctestrun", xctestrun,
                "-destination", destination, "-resultBundlePath", result, "-derivedDataPath", artifacts + "/DerivedData", "-parallel-testing-enabled", "NO"])
        }
        return ToolCommand(executable: "/usr/bin/xcrun", arguments: ["swift", "test", "--package-path", workspace, "--scratch-path", artifacts + "/build", "--skip-build", "--parallel", "--num-workers", "1", "--xunit-output", result])
    }

    private var xcodeArguments: [String] {
        var arguments: [String] = []
        if let container { arguments += [container.hasSuffix(".xcworkspace") ? "-workspace" : "-project", container] }
        if let scheme { arguments += ["-scheme", scheme] }
        if let destination { arguments += ["-destination", destination] }
        return arguments
    }
}
