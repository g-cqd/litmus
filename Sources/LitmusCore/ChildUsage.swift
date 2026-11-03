internal import AemiMetrics
internal import Foundation
internal import Synchronization

/// CPU time consumed by this process's terminated and reaped descendants, in seconds: aemi's
/// `ProcessProbe.childrenCPUNanos()` (`RUSAGE_CHILDREN`).
///
/// Around the baseline suite, which runs alone, the difference over the wall time is how many cores the suite keeps
/// busy by itself (Swift Testing runs tests in parallel inside its process). Litmus sizes its workers from it, so that
/// parallel suites do not oversubscribe the machine. Exact per-child usage waits on swiftlang/swift-subprocess#226; this
/// running total is exact here because the baseline runs alone.
enum ChildUsage {
    static func cpuSeconds() -> Double {
        let usage = ProcessProbe.childrenCPUNanos()
        return Double(usage.user &+ usage.system) / 1e9
    }

    /// Workers such that `workers × parallelism` does not exceed the cores, within 1...`limit`.
    static func workers(parallelism: Double, cores: Int, limit: Int) -> Int {
        let fitting = Int((Double(max(1, cores)) / max(1, parallelism)).rounded(.down))
        return min(max(1, limit), max(1, fitting))
    }
}

/// What a run cost the machine: what a CI runner's budget is set and checked against.
public struct RunCost: Codable, Sendable, Equatable {
    public var wallSeconds: Double = 0
    /// CPU time of Litmus itself and of every process it started and reaped (builds, tests, tools).
    public var litmusCPUSeconds: Double = 0
    public var childCPUSeconds: Double = 0
    /// Peak resident memory of Litmus, and of the largest single child process.
    public var litmusPeakRSSMiB: Double = 0
    public var childPeakRSSMiB: Double = 0
    /// Bytes on disk of the run directory, and of the workspace in it, at their largest (before removal).
    public var runDirectoryMiB: Double = 0
    public var workspaceMiB: Double = 0
    public var builds = 0
    public var testRuns = 0
    public init() {}

    /// The process-level figures now: CPU and peak memory of Litmus and its reaped children (`getrusage`).
    mutating func sample() {
        var own = rusage()
        var children = rusage()
        // SAFETY: getrusage writes one `rusage` through the pointer for the duration of the call; both are local.
        _ = unsafe getrusage(RUSAGE_SELF, &own)
        _ = unsafe getrusage(RUSAGE_CHILDREN, &children)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }
        litmusCPUSeconds = Self.rounded(seconds(own.ru_utime) + seconds(own.ru_stime))
        childCPUSeconds = Self.rounded(seconds(children.ru_utime) + seconds(children.ru_stime))
        // Darwin reports `ru_maxrss` in bytes (Linux in KiB).
        #if os(Linux)
            let unit = 1024.0
        #else
            let unit = 1.0
        #endif
        litmusPeakRSSMiB = Self.rounded(Double(own.ru_maxrss) * unit / 1_048_576)
        childPeakRSSMiB = Self.rounded(Double(children.ru_maxrss) * unit / 1_048_576)
    }

    static func rounded(_ value: Double) -> Double { (value * 10).rounded() / 10 }

    /// Allocated bytes under `directory`, in MiB, without following links; at most 4,000,000 entries are counted.
    static func diskMiB(_ directory: String) -> Double {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard
            let walk = FileManager.default.enumerator(
                at: URL(fileURLWithPath: directory),
                includingPropertiesForKeys: keys,
                options: [],
                errorHandler: { _, _ in true }
            )
        else { return 0 }
        var bytes = 0
        var entries = 0
        while let url = walk.nextObject() as? URL, entries < 4_000_000 {
            entries += 1
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                continue
            }
            bytes += values.totalFileAllocatedSize ?? 0
        }
        return (Double(bytes) / 1_048_576 * 100).rounded() / 100
    }
}

/// Counts a run's builds and test executions across concurrent workers.
final class RunCounter: Sendable {
    private let counts = Mutex((builds: 0, tests: 0))
    func build() { counts.withLock { $0.builds += 1 } }
    func test() { counts.withLock { $0.tests += 1 } }
    var builds: Int { counts.withLock { $0.builds } }
    var tests: Int { counts.withLock { $0.tests } }
}
