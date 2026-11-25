internal import Foundation
internal import ProjectModel
internal import SourceCorpus

/// The local packages a manifest depends on, parsed via `ProjectModel.PackageManifestReader` (SwiftSyntax AST, never
/// fooled by commented-out `.package(path:)` lines), so that a package whose siblings sit outside the snapshot root is
/// told so before a build fails on a missing directory.
enum LocalDependencies {
    /// The directories named by `.package(path: "...")` in `manifest`, as written.
    static func paths(inManifest manifest: String) -> [String] {
        PackageManifestReader.localDependencies(manifest) ?? []
    }

    /// Dependencies of the package at `directory` that resolve outside `root`, as canonical paths.
    static func outside(root: String, packageDirectory directory: String) -> [String] {
        ProjectLayout.externalLocalDependencies(root: root, packageDirectory: directory)
    }

    /// The deepest directory containing every path.
    static func commonAncestor(_ paths: [String]) -> String {
        SourcePath.commonAncestor(paths) ?? "/"
    }

    /// The failure to give when the package at `directory` depends on directories outside `root`, or nil.
    static func diagnosis(root: String, packageDirectory directory: String) -> String? {
        let missing = outside(root: root, packageDirectory: directory)
        guard !missing.isEmpty else { return nil }
        let canonicalPackage = SourcePath.canonical(directory)
        let ancestor = commonAncestor(missing + [canonicalPackage])
        let relative = canonicalPackage.dropFirst(ancestor.count == 1 ? 0 : ancestor.count).drop { $0 == "/" }
        let shown = missing.map { "  " + $0 }.joined(separator: "\n")
        return
            "the package depends on local packages outside the source root, which the snapshot would not contain:\n\(shown)\n"
            + "run from their common parent instead: litmus run \(ancestor) --package-path \(relative)"
    }
}
