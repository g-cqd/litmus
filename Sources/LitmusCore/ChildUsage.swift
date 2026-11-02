#if canImport(Darwin)
    internal import Darwin
#elseif canImport(Glibc)
    internal import Glibc
#endif

/// CPU time consumed by this process's terminated and reaped descendants (`RUSAGE_CHILDREN`), in seconds.
///
/// Around the baseline suite, which runs alone, the difference over the wall time is how many cores the suite keeps
/// busy by itself (Swift Testing runs tests in parallel inside its process). Litmus sizes its workers from it, so that
/// parallel suites do not oversubscribe the machine. Upstream AK-4/AE-7 would return this per child.
enum ChildUsage {
    static func cpuSeconds() -> Double {
        var usage = rusage()
        // SAFETY: getrusage writes one `rusage` into this local through the implicit pointer; nothing escapes the call.
        guard unsafe getrusage(RUSAGE_CHILDREN, &usage) == 0 else { return 0 }
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        return user + system
    }

    /// Workers such that `workers × parallelism` does not exceed the cores, within 1...`limit`.
    static func workers(parallelism: Double, cores: Int, limit: Int) -> Int {
        let fitting = Int((Double(max(1, cores)) / max(1, parallelism)).rounded(.down))
        return min(max(1, limit), max(1, fitting))
    }
}
