internal import Foundation
internal import SourceCorpus

/// A test target of a built `.xctestrun`, its placeholders resolved.
struct XCTestRunTarget: Sendable, Equatable {
    let name: String
    let bundlePath: String
    let hostPath: String?
    let isUITest: Bool
    let environment: [String: String]

    /// No application hosts it: Xcode's own `xctest` agent runs the bundle (package tests, hostless unit tests).
    var isHostless: Bool { !isUITest && (hostPath == nil || hostPath?.hasSuffix("/Agents/xctest") == true) }

    /// The test targets of the `.xctestrun` at `path`, format 1 or 2; `products` replaces `__TESTROOT__`, `platforms`
    /// `__PLATFORMS__`.
    static func targets(xctestrun path: String, products: String, platforms: String) throws -> [XCTestRunTarget] {
        let bytes = try BoundedFileReader.read(path: path, cap: 4 << 20)
        // SAFETY: the API is marked unsafe for its optional output pointer. We pass nil; the input is owned bounded Data.
        let plist = try unsafe PropertyListSerialization.propertyList(from: Data(bytes), options: [], format: nil)
        func resolve(_ text: String) -> String {
            text.replacingOccurrences(of: "__TESTROOT__", with: products)
                .replacingOccurrences(of: "__PLATFORMS__", with: platforms)
        }
        var targets: [XCTestRunTarget] = []
        func visit(_ value: Any, name: String?, depth: Int) throws {
            guard depth <= 64 else { throw LitmusFailure("xctestrun nesting exceeds 64") }
            if let dictionary = value as? [String: Any] {
                if let bundle = dictionary["TestBundlePath"] as? String {
                    let hostPath = (dictionary["TestHostPath"] as? String).map(resolve)
                    func resolveTarget(_ text: String) -> String {
                        let resolved = resolve(text)
                        return hostPath.map { resolved.replacingOccurrences(of: "__TESTHOST__", with: $0) } ?? resolved
                    }
                    let environment = (dictionary["EnvironmentVariables"] as? [String: String] ?? [:])
                        .merging(dictionary["TestingEnvironmentVariables"] as? [String: String] ?? [:]) { a, _ in a }
                    targets.append(
                        XCTestRunTarget(
                            name: dictionary["BlueprintName"] as? String ?? name ?? "",
                            bundlePath: resolveTarget(bundle),
                            hostPath: hostPath,
                            isUITest: dictionary["IsUITestBundle"] as? Bool ?? false,
                            environment: environment.mapValues(resolveTarget)
                        )
                    )
                    return
                }
                for (key, child) in dictionary { try visit(child, name: key, depth: depth + 1) }
            } else if let array = value as? [Any] {
                for child in array { try visit(child, name: name, depth: depth + 1) }
            }
        }
        try visit(plist, name: nil, depth: 0)
        return targets.sorted { $0.name < $1.name }
    }
}
