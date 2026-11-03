internal import Foundation
internal import SourceCorpus

/// Checks discoverable scheme/test-plan configuration before building and validates Xcode's actual test artifact.
/// Generated schemes are validated after build: static inspection cannot infer all Xcode-generated test settings.
public enum XcodeTestConfiguration {
    public static func preflight(driver: BuildDriver, workspace: String) throws {
        guard driver.usesXcode, let scheme = driver.scheme else { return }
        let directory = driver.executionDirectory(workspace: workspace)
        let fm = FileManager.default
        guard let walk = fm.enumerator(atPath: directory) else { return }
        var schemes: [String] = []
        while let relative = walk.nextObject() as? String {
            let name = URL(fileURLWithPath: relative).lastPathComponent
            if name.hasPrefix(".build") || [".git", ".litmus", "DerivedData", "Pods", "Carthage"].contains(name) {
                walk.skipDescendants(); continue
            }
            if relative.hasSuffix("/" + scheme + ".xcscheme") { schemes.append(directory + "/" + relative) }
        }
        if let container = driver.container {
            let preferred = directory + "/" + container + "/xcshareddata/xcschemes/" + scheme + ".xcscheme"
            if fm.fileExists(atPath: preferred) { schemes = [preferred] }
        }
        // An automatically generated or ambiguous scheme must be resolved by Xcode, not guessed here.
        guard schemes.count == 1, let path = schemes.first else { return }
        let bytes = try BoundedFileReader.read(path: path, cap: 4 << 20)
        let delegate = SchemeTests()
        let parser = XMLParser(data: Data(bytes))
        // SAFETY: retain the delegate through synchronous parsing and clear the unowned pointer afterwards.
        unsafe parser.delegate = delegate
        let parsed = withExtendedLifetime(delegate) { parser.parse() }
        unsafe parser.delegate = nil
        guard parsed else { throw LitmusFailure("cannot parse scheme \(scheme): \(path)") }
        if delegate.plans.isEmpty {
            guard driver.testPlan == nil else {
                throw LitmusFailure(
                    "scheme \(scheme) does not reference any test plan; cannot select --test-plan \(driver.testPlan ?? "unknown")"
                )
            }
            guard delegate.testables > 0 else {
                throw LitmusFailure(
                    "scheme \(scheme) (\(path)) configures zero test targets and no test plan; select a testable scheme or use --package-path for a nested package"
                )
            }
            return
        }
        let selectedPlans =
            driver.testPlan.map { name in
                delegate.plans.filter {
                    URL(fileURLWithPath: String($0.dropFirst("container:".count))).deletingPathExtension()
                        .lastPathComponent == name
                }
            } ?? (delegate.defaultPlans.isEmpty ? delegate.plans : delegate.defaultPlans)
        guard !selectedPlans.isEmpty else {
            throw LitmusFailure(
                "scheme \(scheme) does not reference --test-plan \(driver.testPlan ?? "unknown"); available plans: \(delegate.plans.joined(separator: ", "))"
            )
        }
        let planDirectory =
            driver.container.map { URL(fileURLWithPath: directory + "/" + $0).deletingLastPathComponent().path }
            ?? directory
        for reference in selectedPlans {
            guard reference.hasPrefix("container:") else {
                throw LitmusFailure("scheme \(scheme): unsupported test plan reference \(reference) in \(path)")
            }
            let relative = String(reference.dropFirst("container:".count))
            let plan = planDirectory + "/" + relative
            guard fm.fileExists(atPath: plan) else {
                throw LitmusFailure(
                    "scheme \(scheme): test plan \(reference) does not resolve from \(directory); check the scheme reference or use --package-path"
                )
            }
            try validatePlan(
                BoundedFileReader.read(path: plan, cap: 4 << 20),
                path: plan,
                executionDirectory: planDirectory
            )
        }
    }

    public static func validatePlan(_ bytes: [UInt8], path: String, executionDirectory: String) throws {
        guard bytes.count <= 4 << 20 else { throw LitmusFailure("test plan exceeds 4 MiB: \(path)") }
        // JSONSerialization contains the untyped external Xcode test-plan schema at this boundary.
        let value = try JSONSerialization.jsonObject(with: Data(bytes))
        guard let plan = value as? [String: Any], let targets = plan["testTargets"] as? [[String: Any]],
            !targets.filter({ ($0["enabled"] as? Bool) != false }).isEmpty
        else { throw LitmusFailure("test plan \(path) configures zero enabled test targets") }
        for entry in targets where (entry["enabled"] as? Bool) != false {
            guard let target = entry["target"] as? [String: Any],
                let container = target["containerPath"] as? String, container.hasPrefix("container:")
            else { throw LitmusFailure("test plan \(path) has an unsupported or missing target containerPath") }
            let relative = String(container.dropFirst("container:".count))
            let resolved = executionDirectory + (relative.isEmpty ? "" : "/" + relative)
            let fm = FileManager.default
            let valid =
                relative.isEmpty
                ? fm.fileExists(atPath: resolved + "/Package.swift")
                : fm.fileExists(atPath: resolved)
                    && (resolved.hasSuffix(".xcodeproj") || fm.fileExists(atPath: resolved + "/Package.swift"))
            guard valid else {
                throw LitmusFailure(
                    "test plan \(path), target \(target["name"] as? String ?? "unknown"): containerPath \(container) does not resolve to a package/project from \(executionDirectory); use --package-path to run inside the package, or correct the test plan"
                )
            }
        }
    }

    public static func validateArtifacts(artifacts: String, driver: BuildDriver) throws {
        let products = artifacts + "/DerivedData/Build/Products"
        let files = try FileManager.default.contentsOfDirectory(atPath: products).filter { $0.hasSuffix(".xctestrun") }
        guard files.count == 1, let file = files.first else {
            throw LitmusFailure(
                "scheme \(driver.scheme ?? "unknown"): expected one .xctestrun in \(products), found \(files.count); verify the scheme's test action and destination"
            )
        }
        try validateTestRun(
            BoundedFileReader.read(path: products + "/" + file, cap: 4 << 20),
            path: products + "/" + file
        )
    }

    public static func validateTestRun(_ bytes: [UInt8], path: String) throws {
        guard bytes.count <= 4 << 20 else { throw LitmusFailure("xctestrun exceeds 4 MiB: \(path)") }
        // SAFETY: owned bounded data, no output-format pointer.
        let value = try unsafe PropertyListSerialization.propertyList(from: Data(bytes), options: [], format: nil)
        func count(_ value: Any, depth: Int = 0) throws -> Int {
            guard depth <= 64 else { throw LitmusFailure("xctestrun nesting exceeds 64: \(path)") }
            if let dict = value as? [String: Any] {
                if dict["TestBundlePath"] is String { return 1 }
                return try dict.values.reduce(0) { try $0 + count($1, depth: depth + 1) }
            }
            if let array = value as? [Any] { return try array.reduce(0) { try $0 + count($1, depth: depth + 1) } }
            return 0
        }
        guard try count(value) == 0 else { return }
        let dict = value as? [String: Any] ?? [:]
        let info = dict["ContainerInfo"] as? [String: Any] ?? [:]
        let plan = dict["TestPlan"] as? [String: Any] ?? [:]
        throw LitmusFailure(
            "zero supported test targets in \(path); scheme \(info["SchemeName"] as? String ?? "unknown"), test plan \(plan["Name"] as? String ?? "unspecified") resolved no test bundles. Check the scheme's Test action and test plan containerPath; use --package-path for a package inside a larger root. -only-testing cannot add targets absent from this artifact."
        )
    }
}

private final class SchemeTests: NSObject, XMLParserDelegate {
    var plans: [String] = []
    var defaultPlans: [String] = []
    var testables = 0
    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        if elementName == "TestPlanReference", let reference = attributes["reference"] {
            plans.append(reference)
            if attributes["default"] == "YES" { defaultPlans.append(reference) }
        }
        if elementName == "TestableReference", attributes["skipped"] != "YES" { testables += 1 }
    }
}
