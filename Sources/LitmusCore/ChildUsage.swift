internal import AemiMetrics

/// CPU time consumed by this process's terminated and reaped descendants, in seconds: aemi's
/// `ProcessProbe.childrenCPUNanos()` (`RUSAGE_CHILDREN`, aemi ADR 0028).
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
