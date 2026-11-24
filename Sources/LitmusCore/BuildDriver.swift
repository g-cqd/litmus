internal import Foundation
internal import SourceCorpus

/// Chooses SwiftPM for host packages and Xcode for simulator packages, projects and workspaces.
public struct BuildDriver: Codable, Sendable, Equatable {
    public let root: String
    public var testPlan: String?
    public let packagePath: String?
    public let container: String?
    public let scheme: String?
    public let destination: String?
    /// SwiftPM's `--build-system` (`native` rebuilds small packages about twice as fast; `swiftbuild` is the default);
    /// nil keeps the toolchain's default. Ignored for Xcode.
    public var swiftPMBuildSystem: String?
    /// Extra `xcodebuild` arguments for builds and test runs (`--xcodebuild-argument`), such as
    /// `-skipPackagePluginValidation` or `-clonedSourcePackagesDirPath <dir>`; part of provenance and of reuse keys.
    public var xcodebuildArguments: [String] = []

    /// Whether the extra Xcode arguments choose which tests run (`-only-testing:`, `-skip-testing:`, test
    /// configurations). Only `xcodebuild` honours them; Litmus's simulator helper runs the whole bundle.
    public var xcodebuildArgumentsSelectTests: Bool {
        xcodebuildArguments.contains { argument in
            ["-only-testing", "-skip-testing", "-only-test-configuration", "-skip-test-configuration"].contains {
                argument == $0 || argument.hasPrefix($0 + ":")
            }
        }
    }
    public var usesXcode: Bool { scheme != nil }

    /// The arguments every SwiftPM invocation of a run shares, so build, bin path, listing and tests agree.
    /// The scratch directory is the copied workspace's own `.build`, SwiftPM's default: tests often find the package's
    /// executables at `<package>/.build/debug/<tool>` (fcheck's do). The snapshot never copies or verifies `.build`.
    public func swiftPMArguments(workspace: String, artifacts: String) -> [String] {
        [
            "--package-path", executionDirectory(workspace: workspace), "--scratch-path",
            executionDirectory(workspace: workspace) + "/.build",
        ]
            + (swiftPMBuildSystem.map { ["--build-system", $0] } ?? [])
    }

    /// Container paths must remain inside the isolated root. Scheme/destination are required together.
    /// A nil container with a scheme means an Xcode-opened Swift package, not a host `swift test` run.
    public init(
        root: String,
        container: String? = nil,
        packagePath: String? = nil,
        scheme: String?,
        destination: String?
    ) throws {
        if let packagePath {
            let parts = packagePath.split(separator: "/", omittingEmptySubsequences: false)
            guard container == nil, !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw LitmusFailure(
                    "--package-path must be a relative package directory inside root, without . or ..; it cannot be combined with --project"
                )
            }
        }
        self.packagePath = packagePath
        guard (scheme == nil) == (destination == nil) else {
            throw LitmusFailure("scheme and destination must be supplied together")
        }
        if let container {
            guard scheme != nil, !container.hasPrefix("/"),
                !container.split(separator: "/").contains(".."),
                container.hasSuffix(".xcodeproj") || container.hasSuffix(".xcworkspace")
            else {
                throw LitmusFailure(
                    "Xcode container must be a relative project/workspace path inside root; supply scheme and destination"
                )
            }
        }
        self.root = root; self.container = container; self.scheme = scheme; self.destination = destination
    }

    /// The same driver with another destination (a resolved simulator id), keeping every other choice.
    public func with(destination: String) throws -> BuildDriver {
        var copy = try BuildDriver(
            root: root,
            container: container,
            packagePath: packagePath,
            scheme: scheme,
            destination: destination
        )
        copy.testPlan = testPlan
        copy.swiftPMBuildSystem = swiftPMBuildSystem
        copy.xcodebuildArguments = xcodebuildArguments
        return copy
    }

    /// The package execution directory, distinct from the snapshot and evidence root.
    public func executionDirectory(workspace: String) -> String {
        packagePath.map { workspace + "/" + $0 } ?? workspace
    }

    public func validatePackage(workspace: String) throws {
        guard
            (try? FileManager.default.attributesOfItem(atPath: workspace)[.type]) as? FileAttributeType
                == .typeDirectory
        else {
            throw LitmusFailure("source root is not a directory: \(workspace)")
        }
        guard testPlan == nil || usesXcode else { throw LitmusFailure("--test-plan requires --scheme") }
        guard let packagePath else {
            if !usesXcode, let message = LocalDependencies.diagnosis(root: workspace, packageDirectory: workspace) {
                throw LitmusFailure(message)
            }
            return
        }
        let directory = executionDirectory(workspace: workspace)
        let canonical = SourcePath.canonical(directory)
        guard canonical.hasPrefix(SourcePath.canonical(workspace) + "/"),
            FileManager.default.fileExists(atPath: directory + "/Package.swift")
        else {
            throw LitmusFailure(
                "--package-path \(packagePath) must resolve to a package inside root (Package.swift missing or path escapes root)"
            )
        }
        if !usesXcode, let message = LocalDependencies.diagnosis(root: workspace, packageDirectory: directory) {
            throw LitmusFailure(message)
        }
    }

    /// A bounded build-for-testing command. Artifacts must be outside the original source tree.
    public func buildCommand(workspace: String, artifacts: String) -> ToolCommand {
        if usesXcode {
            return ToolCommand(
                executable: "/usr/bin/xcrun",
                arguments: ["xcodebuild", "build-for-testing"] + xcodeArguments + [
                    "-derivedDataPath", artifacts + "/DerivedData", "-parallel-testing-enabled", "NO",
                ] + Self.codeCoverageArguments(for: xcodebuildArguments)
            )
        }
        return ToolCommand(
            executable: "/usr/bin/xcrun",
            arguments: ["swift", "build"] + swiftPMArguments(workspace: workspace, artifacts: artifacts) + [
                "--build-tests", "-j", String(ProcessInfo.processInfo.activeProcessorCount),
            ]
        )
    }

    /// Runs the same entire selected suite for the baseline, every inactive schema and each active mutant.
    /// - Parameters:
    ///   - onlyTesting: Xcode test targets to run (`-only-testing:`); nil runs the whole test plan.
    ///   - resultStream: a file Xcode writes its event stream to while tests run (it must exist), for stopping early.
    ///   - destination: the device to run on, when a worker has its own; the driver's otherwise.
    ///   - derivedData: the DerivedData directory a worker owns; the run's otherwise.
    public func testCommand(
        workspace: String,
        artifacts: String,
        result: String,
        xctestrun: String? = nil,
        onlyTesting: [String]? = nil,
        resultStream: String? = nil,
        destination workerDestination: String? = nil,
        derivedData: String? = nil
    ) throws -> ToolCommand {
        if usesXcode {
            guard let destination = workerDestination ?? destination, let xctestrun else {
                throw LitmusFailure("missing Xcode test artifact/destination")
            }
            return ToolCommand(
                executable: "/usr/bin/xcrun",
                arguments: [
                    "xcodebuild", "test-without-building", "-xctestrun", xctestrun,
                    "-destination", destination, "-resultBundlePath", result, "-derivedDataPath",
                    derivedData ?? artifacts + "/DerivedData", "-parallel-testing-enabled", "NO",
                    // A failing mutant is expected: no sysdiagnose for it.
                    "-collect-test-diagnostics", "never",
                ] + Self.codeCoverageArguments(for: xcodebuildArguments)
                    + (resultStream.map { ["-resultStreamPath", $0] } ?? []) + xcodebuildArguments
                    + (onlyTesting ?? []).sorted().map { "-only-testing:" + $0 }
            )
        }
        return ToolCommand(
            executable: "/usr/bin/xcrun",
            arguments: ["swift", "test"] + swiftPMArguments(workspace: workspace, artifacts: artifacts) + [
                "--skip-build", "--parallel", "--num-workers", "1", "--xunit-output", result,
            ]
        )
    }

    /// Disables Xcode's LLVM code coverage instrumentation unless the caller passed `-enableCodeCoverage`:
    /// Litmus measures reach through its own lightweight activation markers, so profiling every mutant only adds
    /// build and profdata-merge overhead.
    static func codeCoverageArguments(for arguments: [String]) -> [String] {
        arguments.contains("-enableCodeCoverage") ? [] : ["-enableCodeCoverage", "NO"]
    }

    /// `ARCHS` and `ONLY_ACTIVE_ARCH` for a simulator build: Xcode would otherwise build the app for both simulator
    /// architectures while Swift packages in the same build hold only the host's. An explicit setting wins.
    static func simulatorArchitectureSettings(for arguments: [String], destination: String?) -> [String] {
        guard destination?.contains("Simulator") == true else { return [] }
        guard !arguments.contains(where: { $0.hasPrefix("ARCHS=") || $0.hasPrefix("ONLY_ACTIVE_ARCH=") }) else {
            return []
        }
        #if arch(arm64)
            return ["ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES"]
        #elseif arch(x86_64)
            return ["ARCHS=x86_64", "ONLY_ACTIVE_ARCH=YES"]
        #else
            return []
        #endif
    }

    private var xcodeArguments: [String] {
        var arguments: [String] = []
        if let container { arguments += [container.hasSuffix(".xcworkspace") ? "-workspace" : "-project", container] }
        if let scheme { arguments += ["-scheme", scheme] }
        if let destination { arguments += ["-destination", destination] }
        if let testPlan { arguments += ["-testPlan", testPlan] }
        return arguments + xcodebuildArguments
            + Self.simulatorArchitectureSettings(for: xcodebuildArguments, destination: destination)
    }
}
