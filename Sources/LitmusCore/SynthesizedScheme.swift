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
    /// of every project the workspace lists (`XcodeWorkspace`) inside the run's workspace copy; UI-test targets too
    /// when `includeUITests`. Listed projects outside the copy are left out: Litmus never mutates them.
    /// - Returns: the scheme's path, the targets it tests by name, and the listed projects left out.
    /// - Throws: `LitmusFailure` when the workspace cannot be read or no unit-test target is found.
    public static func install(
        workspace: String,
        container: String,
        includeUITests: Bool = false
    ) throws -> (path: String, targets: [String], outside: [String]) {
        let containerPath = workspace + "/" + container
        let containerDirectory = (containerPath as NSString).deletingLastPathComponent
        var projects: [String]
        var outside: [String] = []
        if container.hasSuffix(".xcodeproj") {
            projects = [SourcePath.canonical(containerPath)]
        } else {
            guard let listed = XcodeWorkspace.projects(workspace: SourcePath.canonical(containerPath)) else {
                throw LitmusFailure("--all-test-targets: cannot read \(container)/contents.xcworkspacedata")
            }
            let copy = SourcePath.canonical(workspace) + "/"
            projects = listed.filter { $0.hasPrefix(copy) }
            outside = listed.filter { !$0.hasPrefix(copy) }
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
        return (path, targets.map(\.name), outside)
    }
}
