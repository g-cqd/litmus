internal import Foundation
internal import SourceCorpus

/// The local packages a manifest depends on, found without running the package tool, so that a package whose siblings
/// are outside the snapshot root is told so before a build fails on a missing directory.
enum LocalDependencies {
    /// The directories named by `.package(path: "...")` in `manifest`, as written.
    static func paths(inManifest manifest: String) -> [String] {
        var result: [String] = []
        for match in manifest.matches(of: /\.package\s*\(\s*(?:name\s*:\s*"[^"]*"\s*,\s*)?path\s*:\s*"([^"\n]+)"/) {
            result.append(String(match.1))
        }
        return result
    }

    /// Dependencies of the package at `directory` that resolve outside `root`, as canonical paths.
    static func outside(root: String, packageDirectory directory: String) -> [String] {
        guard let manifest = try? String(contentsOfFile: directory + "/Package.swift", encoding: .utf8) else {
            return []
        }
        let canonicalRoot = SourcePath.canonical(root)
        var outside: [String] = []
        for path in paths(inManifest: manifest) {
            let absolute = path.hasPrefix("/") ? path : directory + "/" + path
            let resolved = (absolute as NSString).standardizingPath
            if resolved != canonicalRoot, !resolved.hasPrefix(canonicalRoot + "/"), !outside.contains(resolved) {
                outside.append(resolved)
            }
        }
        return outside
    }

    /// The deepest directory containing every path.
    static func commonAncestor(_ paths: [String]) -> String {
        let split = paths.map { $0.split(separator: "/", omittingEmptySubsequences: true).map(String.init) }
        guard var common = split.first else { return "/" }
        for other in split.dropFirst() {
            var length = 0
            while length < min(common.count, other.count), common[length] == other[length] { length += 1 }
            common = Array(common[..<length])
        }
        return "/" + common.joined(separator: "/")
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
