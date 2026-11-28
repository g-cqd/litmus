internal import Foundation
internal import SourceCorpus

#if canImport(FoundationXML)
    internal import FoundationXML
#endif

/// Narrows an Xcode build to some test targets by editing the scheme and its test plan in the run's workspace copy:
/// the other test targets leave the scheme's testables, its build-for-testing roots and the plan, so `build-for-testing`
/// builds the kept bundles and what they depend on (`-only-testing:` does not narrow a build). Never the subject's
/// own files: the caller passes a copy.
enum XcodeBuildNarrowing {
    /// Keeps the test targets of `keep` that the plan lists. Returns the kept targets, or why the build stays whole.
    static func narrow(
        workspace: String,
        container: String,
        scheme: String,
        testPlan: String?,
        keep: Set<String>
    ) -> Result<[String], LitmusFailure> {
        #if os(macOS)
            do {
                return .success(try edit(workspace, container, scheme, testPlan, keep))
            } catch let failure as LitmusFailure {
                return .failure(failure)
            } catch {
                return .failure(LitmusFailure("\(error)"))
            }
        #else
            return .failure(LitmusFailure("Xcode builds run on macOS only"))
        #endif
    }

    #if os(macOS)
        private static func edit(
            _ workspace: String,
            _ container: String,
            _ scheme: String,
            _ testPlan: String?,
            _ keep: Set<String>
        ) throws -> [String] {
            guard container.hasSuffix(".xcodeproj"), !scheme.contains("/") else {
                throw LitmusFailure("the scheme is not a shared scheme of an .xcodeproj")
            }
            let root = SourcePath.canonical(workspace)
            let schemePath = try inside(
                root,
                root + "/" + container + "/xcshareddata/xcschemes/" + scheme + ".xcscheme"
            )
            let document = try XMLDocument(
                contentsOf: URL(fileURLWithPath: schemePath),
                options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever]
            )
            guard let schemeElement = document.rootElement(), schemeElement.name == "Scheme",
                let testAction = schemeElement.elements(forName: "TestAction").first,
                let buildAction = schemeElement.elements(forName: "BuildAction").first,
                buildAction.attribute(forName: "buildImplicitDependencies")?.stringValue == "YES"
            else { throw LitmusFailure("the scheme has no test action, or builds without implicit dependencies") }
            var kept: Set<String> = []
            var plan: (path: String, data: Data)?
            let references =
                testAction.elements(forName: "TestPlans").first?.elements(forName: "TestPlanReference") ?? []
            if !references.isEmpty {
                let chosen = references.filter { reference in
                    let path = reference.attribute(forName: "reference")?.stringValue ?? ""
                    if let testPlan {
                        return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent == testPlan
                    }
                    return references.count == 1 || reference.attribute(forName: "default")?.stringValue == "YES"
                }
                guard chosen.count == 1, let reference = chosen.first,
                    let location = reference.attribute(forName: "reference")?.stringValue,
                    location.hasPrefix("container:")
                else { throw LitmusFailure("the scheme's effective test plan is ambiguous") }
                let directory = (root + "/" + container as NSString).deletingLastPathComponent
                let planPath = try inside(root, directory + "/" + location.dropFirst("container:".count))
                guard
                    var json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: planPath)))
                        as? [String: Any], let entries = json["testTargets"] as? [[String: Any]]
                else { throw LitmusFailure("the test plan cannot be read") }
                let retained = entries.filter { entry in
                    guard let name = (entry["target"] as? [String: Any])?["name"] as? String else { return false }
                    return keep.contains(name)
                }
                kept = Set(retained.compactMap { ($0["target"] as? [String: Any])?["name"] as? String })
                json["testTargets"] = retained
                plan = (
                    planPath, try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
                )
                for other in references where other !== reference { other.detach() }
            }
            let testables = testAction.elements(forName: "Testables").first?.elements(forName: "TestableReference")
            for testable in testables ?? [] {
                if let name = blueprint(testable), keep.contains(name) { kept.insert(name) } else { testable.detach() }
            }
            guard !kept.isEmpty else {
                throw LitmusFailure("none of the covering test targets is in the scheme's tests")
            }
            let builds = buildAction.elements(forName: "BuildActionEntries").first?.elements(
                forName: "BuildActionEntry"
            )
            for entry in builds ?? [] where !kept.contains(blueprint(entry) ?? "") {
                if entry.attribute(forName: "buildForTesting")?.stringValue == "YES" {
                    entry.attribute(forName: "buildForTesting")?.stringValue = "NO"
                }
            }
            if let plan { try plan.data.write(to: URL(fileURLWithPath: plan.path), options: .atomic) }
            try document.xmlData(options: [.nodePreserveAll]).write(
                to: URL(fileURLWithPath: schemePath),
                options: .atomic
            )
            return kept.sorted()
        }

        /// The target name of a scheme element's `BuildableReference`.
        private static func blueprint(_ element: XMLElement) -> String? {
            element.elements(forName: "BuildableReference").first?.attribute(forName: "BlueprintName")?.stringValue
        }

        /// `path` when it resolves to a regular file under `root` (no link out of the copy).
        private static func inside(_ root: String, _ path: some StringProtocol) throws -> String {
            let resolved = SourcePath.canonical(String(path))
            var isDirectory: ObjCBool = false
            guard resolved.hasPrefix(root + "/"), !resolved.split(separator: "/").contains(".."),
                unsafe FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory),
                !isDirectory.boolValue
            else { throw LitmusFailure("\(path) is not a file inside the workspace copy") }
            return resolved
        }
    #endif
}
