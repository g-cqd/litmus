internal import Foundation

/// What a harness can honour; the runner adapts its policy to it instead of branching on harness types.
public struct HarnessCapabilities: Sendable, Equatable {
    /// Workers that may run at once against one build.
    public var maximumWorkers: Int
    /// Whether ``TestRunRequest/onlySwiftTesting`` is honoured, so a kill can be confirmed on its failing tests alone.
    public var selectsTests: Bool
    /// Whether ``TestRunRequest/onlyModules`` is honoured, with ``TestRunResult/moduleCounts`` reported.
    public var selectsModules: Bool
    /// Whether it runs Swift Testing itself and so can repeat the suite, skip tests and cap its width; `xcodebuild`
    /// cannot.
    public var controlsSwiftTesting: Bool

    public init(
        maximumWorkers: Int = 1,
        selectsTests: Bool = false,
        selectsModules: Bool = false,
        controlsSwiftTesting: Bool = false
    ) {
        self.maximumWorkers = max(1, maximumWorkers)
        self.selectsTests = selectsTests
        self.selectsModules = selectsModules
        self.controlsSwiftTesting = controlsSwiftTesting
    }
}

/// Runs the subject's tests against the current build products.
public protocol TestHarness: Sendable {
    /// What the harness honours.
    var capabilities: HarnessCapabilities { get }
    /// A description for provenance.
    var kind: String { get }
    func run(_ request: TestRunRequest) async throws -> TestRunResult
}

extension TestHarness {
    public var maximumWorkers: Int { capabilities.maximumWorkers }
    public var selectsTests: Bool { capabilities.selectsTests }
    public var selectsModules: Bool { capabilities.selectsModules }
    public var controlsSwiftTesting: Bool { capabilities.controlsSwiftTesting }
}
