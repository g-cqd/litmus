internal import Foundation
internal import SourceCorpus
internal import Synchronization

/// A test bundle a shared-process helper can serve.
struct SharedBundle: Sendable, Equatable {
    let module: String
    let binary: String
    let hasSwiftTesting: Bool
}

/// Launch specification for a shared-process helper's `--serve` loop.
struct ServeCommand: Sendable {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    let directory: String
}

/// Swift Testing configuration payload sent to a shared worker over its command FIFO.
struct SharedWorkerConfiguration: Codable, Sendable, Equatable {
    var filter: [String]?
    var skip: [String]?
    var experimentalMaximumParallelizationWidth: Int?
}

/// Backend harness whose test bundles can be kept loaded inside a helper process.
protocol SharedProcessBackend: TestHarness {
    var sharedBundles: [SharedBundle] { get }
    var logs: String { get }
    func serveCommand(bundle: SharedBundle, helper: String, arguments: [String], environment: [String: String]) async
        -> ServeCommand
}

/// Session-level lifecycle hooks for a shared-process harness.
protocol SharedProcessControl: AnyObject, Sendable {
    var mode: SharedProcessMode { get }
    var bundleCount: Int { get }
    var statistics: SharedProcessStatistics { get }
    func prepare(batch: [Mutation])
    func decide(covered: Int, workers: Int, suiteNanoseconds: Int64, spawnNanoseconds: Int64) -> String?
    func shutdown()
}

/// Counts of decisions made inside shared workers vs. fresh processes.
public struct SharedProcessStatistics: Sendable, Equatable {
    public var sharedKills = 0
    public var sharedPasses = 0
    public var freshRuns = 0
    public var workersStarted = 0
    public var workersRetired = 0
    public var processCached: Set<String> = []
    public var batchesEngaged = 0
    public var batchesDeclined = 0
}

extension SwiftPMDirectHarness: SharedProcessBackend {
    var sharedBundles: [SharedBundle] {
        bundles.map {
            SharedBundle(module: $0.module, binary: $0.binaryPath, hasSwiftTesting: $0.swiftTestingCount > 0)
        }
    }

    func serveCommand(bundle: SharedBundle, helper: String, arguments: [String], environment: [String: String]) async
        -> ServeCommand
    {
        var child = subjectEnvironment(nil)
        child["DYLD_FRAMEWORK_PATH"] = toolchain.frameworks
        child["DYLD_LIBRARY_PATH"] = toolchain.libraries
        child.merge(environment) { _, new in new }
        return ServeCommand(executable: helper, arguments: arguments, environment: child, directory: workspace)
    }
}

extension SimulatorDirectHarness: SharedProcessBackend {
    var sharedBundles: [SharedBundle] {
        bundles.map { SharedBundle(module: $0.module, binary: $0.binary, hasSwiftTesting: true) }
    }

    func serveCommand(bundle: SharedBundle, helper: String, arguments: [String], environment: [String: String]) async
        -> ServeCommand
    {
        guard let full = bundles.first(where: { $0.module == bundle.module }) else {
            return ServeCommand(executable: "/usr/bin/false", arguments: [], environment: [:], directory: workspace)
        }
        var variables = self.environment(nil, bundle: full)
        for (name, value) in environment { variables["SIMCTL_CHILD_" + name] = value }
        let udid = await fleet.nextDevice().udid
        let spawn = ["spawn", udid, helper, "--serve"] + arguments
        if self.helper.simctl == "/usr/bin/xcrun" {
            return ServeCommand(
                executable: "/usr/bin/xcrun",
                arguments: ["simctl"] + spawn,
                environment: variables,
                directory: workspace
            )
        }
        return ServeCommand(
            executable: self.helper.simctl,
            arguments: spawn,
            environment: variables,
            directory: workspace
        )
    }
}
