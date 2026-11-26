internal import Foundation
internal import ProjectModel
internal import SourceCorpus

/// `--all-test-targets`: a shared scheme testing every unit-test target of the Xcode project or workspace, written
/// into the run's own workspace (never the subject's tree), for workspaces whose schemes leave test targets out.
/// Built on analyzerkit's `XcodeNativeTargets` and `XcodeSchemeWriter`.
public enum SynthesizedScheme {
    /// The scheme's name, which the run's driver names.
    public static let name = "__LitmusAllUnitTests"

    /// Writes the scheme into `container` (relative to `workspace`), testing the unit-test targets of the project, or
    /// of every project under the workspace's directory; UI-test targets too when `includeUITests`.
    /// - Returns: the scheme's path and the targets it tests, by name.
    /// - Throws: `LitmusFailure` when no unit-test target is found.
    public static func install(
        workspace: String,
        container: String,
        includeUITests: Bool = false
    ) throws -> (path: String, targets: [String]) {
        let containerPath = workspace + "/" + container
        let containerDirectory = (containerPath as NSString).deletingLastPathComponent
        let projects: [String]
        if container.hasSuffix(".xcodeproj") {
            projects = [containerPath]
        } else {
            let layout = ProjectLayout.discover(paths: [SourcePath.canonical(containerDirectory)])
            projects = (layout?.containers ?? []).filter { $0.hasSuffix(".xcodeproj") }.sorted()
        }
        let targets = projects.flatMap { project in
            (XcodeNativeTargets.read(project: SourcePath.canonical(project)) ?? []).filter {
                $0.isUnitTest || includeUITests && $0.isUITest
            }
        }
        guard !targets.isEmpty else {
            throw LitmusFailure("--all-test-targets: no unit-test target in \(container)")
        }
        let directory = containerPath + "/xcshareddata/xcschemes"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = directory + "/" + name + ".xcscheme"
        let xml = XcodeSchemeWriter.testScheme(targets, containerDirectory: SourcePath.canonical(containerDirectory))
        try Data(xml.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        return (path, targets.map(\.name))
    }
}
