internal import Foundation

/// One test-suite execution against the current build.
public struct TestRunRequest: Sendable {
    /// File prefix for this run's evidence in the run's `logs` directory.
    public let name: String
    /// The mutant to activate, or empty for an inactive control.
    public let activeID: String
    /// A fresh directory for activation markers.
    public let coverageDirectory: String
    /// A fresh `TMPDIR`, so tests that use fixed temporary names do not collide across workers.
    public let temporaryDirectory: String
    /// Deadline for the whole suite, in seconds.
    public let deadline: Int
    /// Stop at the first structured test failure (Swift Testing event stream).
    public let failFast: Bool
    /// Run only these Swift Testing tests (identifiers without their source location), and no XCTest; nil runs all.
    public var onlySwiftTesting: [String]? = nil
    /// The memory limit and priority every process of the run gets; the harness adds its own monitor.
    public var supervision = Supervision()
    /// Run only the test bundles of these modules (the test targets that can reach the mutant); nil runs every one.
    public var onlyModules: Set<String>? = nil
    /// Swift Testing tests not to run (flaky at baseline), identifiers without their source location.
    public var skipSwiftTesting: [String] = []
    /// Run every Swift Testing test this many times (`--repetitions`): the flakiness probe.
    public var repetitions: Int? = nil
    /// The most Swift Testing tests run at once in one process (`--experimental-maximum-parallelization-width`).
    public var parallelizationWidth: Int? = nil
    /// Collect single-pass per-test reach during this run by interleaving `{"litmusReach":"<id>"}` records into the
    /// serial Swift Testing event stream via a FIFO.
    public var collectPerTestReach = false
    /// The run's ``ActivationEnvironment`` token, which the schemas it built read their variables under.
    public var environmentToken = ""
    /// Test modules never run (`--skip-failing-targets` quarantine): their bundles are left out.
    public var skipModules: Set<String> = []
    /// Run alone on the machine: a confirmation or rerun, never in a shared worker.
    public var alone = false
    /// Whether a narrowed survivor will be rechecked in a fresh process against its whole covering modules; a shared
    /// worker may then report its pass without an immediate fresh copy of the same narrowed run.
    public var rechecksNarrowedSurvivors = false
}
