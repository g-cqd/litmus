import Foundation
import Testing

@testable import LitmusCore

@Test func `nested packages retain the snapshot root but execute inside the package`() throws {
    let driver = try BuildDriver(
        root: "/repo",
        packagePath: "Modules/Library",
        scheme: "Library",
        destination: "platform=iOS Simulator,id=ABC"
    )
    #expect(driver.executionDirectory(workspace: "/snapshot") == "/snapshot/Modules/Library")
    #expect(!driver.buildCommand(workspace: "/snapshot", artifacts: "/artifacts").arguments.contains("-project"))
    let host = try BuildDriver(root: "/repo", packagePath: "Modules/Library", scheme: nil, destination: nil)
    #expect(
        host.swiftPMArguments(workspace: "/snapshot", artifacts: "/artifacts").contains("/snapshot/Modules/Library")
    )
    #expect(try ArtifactCodec.decode(BuildDriver.self, bytes: ArtifactCodec.json(driver)) == driver)
}

@Test func `package paths reject traversal absolute paths and conflicting project selection`() {
    for path in ["/outside", "../outside", "A/../../outside", ".", ""] {
        #expect(throws: (any Error).self) {
            try BuildDriver(root: "/repo", packagePath: path, scheme: nil, destination: nil)
        }
    }
    #expect(throws: (any Error).self) {
        try BuildDriver(
            root: "/repo",
            container: "App.xcodeproj",
            packagePath: "Pkg",
            scheme: "App",
            destination: "macOS"
        )
    }
}

@Test func `empty xctestrun explains scheme plan and corrective action`() throws {
    let plist: [String: Any] = [
        "ContainerInfo": ["SchemeName": "Library"], "TestPlan": ["Name": "UnitTests"], "TestConfigurations": [Any](),
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    do {
        try XcodeTestConfiguration.validateTestRun(Array(data), path: "/artifacts/Library.xctestrun")
        Issue.record("empty test configuration was accepted")
    } catch {
        let message = String(describing: error)
        #expect(message.contains("Library"))
        #expect(message.contains("UnitTests"))
        #expect(message.contains("zero"))
        #expect(message.contains("--package-path"))
    }
}

@Test func `test plan validates container paths relative to the execution directory`() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    try FileManager.default.createDirectory(atPath: root + "/Pkg", withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: root) }
    try Data().write(to: URL(fileURLWithPath: root + "/Pkg/Package.swift"))
    let data = Array(#"{"testTargets":[{"target":{"containerPath":"container:","name":"LibraryTests"}}]}"#.utf8)
    try XcodeTestConfiguration.validatePlan(data, path: "Unit.xctestplan", executionDirectory: root + "/Pkg")
    #expect(throws: (any Error).self) {
        try XcodeTestConfiguration.validatePlan(data, path: "Unit.xctestplan", executionDirectory: root)
    }
    #expect(throws: (any Error).self) {
        try XcodeTestConfiguration.validatePlan(
            Array(#"{"testTargets":[]}"#.utf8),
            path: "Empty",
            executionDirectory: root
        )
    }
}

private func configurationFixture() throws -> String {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    try FileManager.default.createDirectory(
        atPath: root + "/Pkg/.swiftpm/xcode/xcshareddata/xcschemes",
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        atPath: root + "/Sibling/Sources/Sibling",
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(atPath: root + "/Pkg/Sources/Library", withIntermediateDirectories: true)
    let manifest =
        "// swift-tools-version: 6.4\nimport PackageDescription\nlet package = Package(name: \"Library\", targets: [.target(name: \"Library\")])"
    try Data(manifest.utf8).write(to: URL(fileURLWithPath: root + "/Pkg/Package.swift"))
    try Data(manifest.replacingOccurrences(of: "Library", with: "Sibling").utf8).write(
        to: URL(fileURLWithPath: root + "/Sibling/Package.swift")
    )
    for (directory, module) in [("Pkg", "Library"), ("Sibling", "Sibling")] {
        try Data("public func choose(_ flag: Bool) -> Int { flag ? 1 : 2 }".utf8)
            .write(to: URL(fileURLWithPath: root + "/" + directory + "/Sources/" + module + "/F.swift"))
    }
    return root
}

@Test func `nested package scope excludes sibling mutations and preserves repository relative identities`() async throws
{
    let root = try configurationFixture()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let plan = try await MutationPlanner.plan(root: root, packagePath: "Pkg")
    #expect(!plan.mutations.isEmpty)
    #expect(plan.mutations.allSatisfy { $0.path.hasPrefix("Pkg/") })
    let diff = root + "/changes.diff"
    try Data(
        "diff --git a/Sibling/Sources/Sibling/F.swift b/Sibling/Sources/Sibling/F.swift\n--- a/Sibling/Sources/Sibling/F.swift\n+++ b/Sibling/Sources/Sibling/F.swift\n@@ -1 +1 @@\n-old\n+new\n"
            .utf8
    ).write(to: URL(fileURLWithPath: diff))
    let scope = try ChangeScope.load(diffFile: diff, root: root, diffRoot: root, breadth: .lines)
    let changed = try await MutationPlanner.plan(root: root, packagePath: "Pkg", scope: scope)
    #expect(changed.mutations.isEmpty)
}

@Test func `shared schemes fail preflight on absent targets missing plans and invalid container paths`() throws {
    let root = try configurationFixture()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let path = root + "/Pkg/.swiftpm/xcode/xcshareddata/xcschemes/Library.xcscheme"
    let driver = try BuildDriver(root: root, packagePath: "Pkg", scheme: "Library", destination: "macOS")
    for xml in [
        "<Scheme><TestAction><Testables/></TestAction></Scheme>",
        "<Scheme><TestAction><TestPlans><TestPlanReference reference=\"container:Missing.xctestplan\"/></TestPlans></TestAction></Scheme>",
    ] {
        try Data(xml.utf8).write(to: URL(fileURLWithPath: path))
        #expect(throws: (any Error).self) { try XcodeTestConfiguration.preflight(driver: driver, workspace: root) }
    }
    try Data(
        "<Scheme><TestAction><Testables><TestableReference skipped=\"NO\"/></Testables></TestAction></Scheme>".utf8
    ).write(to: URL(fileURLWithPath: path))
    try XcodeTestConfiguration.preflight(driver: driver, workspace: root)
}

@Test func `package validation refuses missing manifests and symlink escape`() throws {
    let root = try configurationFixture()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let valid = try BuildDriver(root: root, packagePath: "Pkg", scheme: nil, destination: nil)
    try valid.validatePackage(workspace: root)
    let missing = try BuildDriver(root: root, packagePath: "Missing", scheme: nil, destination: nil)
    #expect(throws: (any Error).self) { try missing.validatePackage(workspace: root) }
    try FileManager.default.createSymbolicLink(atPath: root + "/Escape", withDestinationPath: "/tmp")
    let escaped = try BuildDriver(root: root, packagePath: "Escape", scheme: nil, destination: nil)
    #expect(throws: (any Error).self) { try escaped.validatePackage(workspace: root) }
}

private struct NoExecution: ProcessExecutor {
    func execute(
        _ command: ToolCommand,
        directory: String,
        environment: [String: String],
        timeout: Int,
        supervision: Supervision
    ) async throws -> ProcessOutput {
        Issue.record("preflight unexpectedly executed \(command.arguments)")
        throw LitmusFailure("unexpected execution")
    }
}

@Test func `existing output is rejected before executing or changing its files`() async throws {
    let root = try configurationFixture()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let driver = try BuildDriver(root: root + "/Pkg", scheme: nil, destination: nil)
    let output = root + "/existing"
    try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: URL(fileURLWithPath: output + "/evidence"))
    do {
        _ = try await MutationRunner(executor: NoExecution()).run(driver: driver, outputDirectory: output)
        Issue.record("existing output was accepted")
    } catch {
        let message = String(describing: error)
        #expect(message.contains(output))
        #expect(message.contains("--output"))
        #expect(message.contains("--resume"))
    }
    #expect(try String(contentsOfFile: output + "/evidence", encoding: .utf8) == "keep")
}

@Test func `valid nonempty xctestrun is accepted and excessive nesting is refused`() throws {
    let valid: [String: Any] = [
        "TestConfigurations": [["TestTargets": [["TestBundlePath": "__TESTROOT__/Library.xctest"]]]]
    ]
    try XcodeTestConfiguration.validateTestRun(
        Array(PropertyListSerialization.data(fromPropertyList: valid, format: .xml, options: 0)),
        path: "Library.xctestrun"
    )
    var deep: [String: Any] = ["leaf": "value"]
    for _ in 0..<70 { deep = ["nested": deep] }
    let bytes = Array(try PropertyListSerialization.data(fromPropertyList: deep, format: .xml, options: 0))
    #expect(throws: (any Error).self) { try XcodeTestConfiguration.validateTestRun(bytes, path: "deep.xctestrun") }
}

@Test func `explicit test plan is passed to Xcode and requires a scheme`() throws {
    var driver = try BuildDriver(root: "/repo", scheme: "Library", destination: "macOS")
    driver.testPlan = "Focused"
    let arguments = driver.buildCommand(workspace: "/copy", artifacts: "/artifacts").arguments
    #expect(arguments.contains("-testPlan"))
    #expect(arguments.contains("Focused"))
}

@Test func `explicit plan selection rejects unknown plans and validates only the selected plan`() throws {
    let root = try configurationFixture()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let schemePath = root + "/Pkg/.swiftpm/xcode/xcshareddata/xcschemes/Library.xcscheme"
    try Data(
        "<Scheme><TestAction><TestPlans><TestPlanReference reference=\"container:Good.xctestplan\"/><TestPlanReference reference=\"container:Missing.xctestplan\"/></TestPlans></TestAction></Scheme>"
            .utf8
    ).write(to: URL(fileURLWithPath: schemePath))
    try Data(#"{"testTargets":[{"target":{"containerPath":"container:","name":"LibraryTests"}}]}"#.utf8).write(
        to: URL(fileURLWithPath: root + "/Pkg/Good.xctestplan")
    )
    var driver = try BuildDriver(root: root, packagePath: "Pkg", scheme: "Library", destination: "macOS")
    driver.testPlan = "Good"
    try XcodeTestConfiguration.preflight(driver: driver, workspace: root)
    driver.testPlan = "Unknown"
    #expect(throws: (any Error).self) { try XcodeTestConfiguration.preflight(driver: driver, workspace: root) }
}

@Test func `disabled targets malformed plans and corrupt artifacts cannot pass configuration checks`() throws {
    let disabled = Array(
        #"{"testTargets":[{"enabled":false,"target":{"containerPath":"container:","name":"LibraryTests"}}]}"#.utf8
    )
    #expect(throws: (any Error).self) {
        try XcodeTestConfiguration.validatePlan(disabled, path: "Disabled", executionDirectory: "/tmp")
    }
    #expect(throws: (any Error).self) {
        try XcodeTestConfiguration.validatePlan(Array("not json".utf8), path: "Malformed", executionDirectory: "/tmp")
    }
    #expect(throws: (any Error).self) {
        try XcodeTestConfiguration.validateTestRun(Array("not plist".utf8), path: "Malformed")
    }
}

@Test func `legacy build driver artifacts decode without nested package or selected plan fields`() throws {
    let bytes = Array(#"{"root":"/repo","xcodebuildArguments":[]}"#.utf8)
    let driver = try ArtifactCodec.decode(BuildDriver.self, bytes: bytes)
    #expect(driver.packagePath == nil)
    #expect(driver.testPlan == nil)
    #expect(driver.executionDirectory(workspace: "/copy") == "/copy")
}

@Test func `snapshot preserves package shared schemes and plan context`() async throws {
    let root = try configurationFixture()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let file = "Pkg/.swiftpm/xcode/xcshareddata/xcschemes/Library.xcscheme"
    try Data("<Scheme/>".utf8).write(to: URL(fileURLWithPath: root + "/" + file))
    let copy = root + "-snapshot"
    defer { try? FileManager.default.removeItem(atPath: copy) }
    let snapshot = try await WorkspaceSnapshot.create(source: root, destination: copy)
    #expect(snapshot.entries.contains { $0.path == file })
    #expect(FileManager.default.fileExists(atPath: copy + "/" + file))
}

@Test func `default test plan is checked without rejecting an unselected missing plan`() throws {
    let root = try configurationFixture()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let scheme = root + "/Pkg/.swiftpm/xcode/xcshareddata/xcschemes/Library.xcscheme"
    try Data(
        "<Scheme><TestAction><TestPlans><TestPlanReference reference=\"container:Good.xctestplan\" default=\"YES\"/><TestPlanReference reference=\"container:Missing.xctestplan\"/></TestPlans></TestAction></Scheme>"
            .utf8
    ).write(to: URL(fileURLWithPath: scheme))
    try Data(#"{"testTargets":[{"target":{"containerPath":"container:","name":"LibraryTests"}}]}"#.utf8).write(
        to: URL(fileURLWithPath: root + "/Pkg/Good.xctestplan")
    )
    let driver = try BuildDriver(root: root, packagePath: "Pkg", scheme: "Library", destination: "macOS")
    try XcodeTestConfiguration.preflight(driver: driver, workspace: root)
}

@Test func `explicit project scheme takes precedence over a same-named package scheme`() throws {
    let root = try configurationFixture()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let project = root + "/App.xcodeproj/xcshareddata/xcschemes"
    try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
    try Data("<Scheme><TestAction><Testables/></TestAction></Scheme>".utf8).write(
        to: URL(fileURLWithPath: project + "/Library.xcscheme")
    )
    try Data(
        "<Scheme><TestAction><Testables><TestableReference skipped=\"NO\"/></Testables></TestAction></Scheme>".utf8
    ).write(to: URL(fileURLWithPath: root + "/Pkg/.swiftpm/xcode/xcshareddata/xcschemes/Library.xcscheme"))
    let driver = try BuildDriver(root: root, container: "App.xcodeproj", scheme: "Library", destination: "macOS")
    #expect(throws: (any Error).self) { try XcodeTestConfiguration.preflight(driver: driver, workspace: root) }
}

@Test func `xcodebuild arguments that select tests keep the run on xcodebuild`() throws {
    var driver = try BuildDriver(root: "/repo", scheme: "Library", destination: "platform=iOS Simulator,id=ABC")
    #expect(!driver.xcodebuildArgumentsSelectTests)
    driver.xcodebuildArguments = ["-skipMacroValidation", "-parallel-testing-enabled", "NO"]
    #expect(!driver.xcodebuildArgumentsSelectTests)
    for argument in [
        "-only-testing:LibraryTests/Suite", "-skip-testing:LibraryTests", "-only-test-configuration",
        "-skip-test-configuration",
    ] {
        driver.xcodebuildArguments = ["-skipMacroValidation", argument]
        #expect(driver.xcodebuildArgumentsSelectTests, "\(argument)")
    }
}
