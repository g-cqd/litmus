internal import Foundation
internal import Synchronization

/// The wall times of this run's finished mutant runs, which set later mutants' deadlines.
///
/// The static deadline comes from the whole baseline (`timeoutFactor` × its wall time + 2 s, at most `timeoutCap`),
/// which on a simulator is mostly the launch of every test module. A mutant's run executes far less: its reaching
/// tests, or its covering modules. Once enough runs of the same kind have finished, a hanging mutant waits
/// `timeoutFactor` × their 95th percentile + 2 s instead, never more than the static deadline and never less than
/// `minimumTimeout`. A run kind is narrowed (named tests) or a set of covering modules; only runs that ended on their
/// own (passed or failed) are samples, so a timeout never lengthens the next one.
final class MutantTimings: Sendable {
    /// Samples needed before a kind's observed times replace the static deadline.
    static let minimumSamples = 8

    private let samples = Mutex<[String: [Int64]]>([:])

    /// The kind of a run: its named tests, or the modules it runs (every module when nil).
    static func kind(tests: [String]?, modules: Set<String>?) -> String {
        if tests != nil { return "tests" }
        return "modules:" + (modules?.sorted().joined(separator: ",") ?? "*")
    }

    func record(_ nanoseconds: Int64, kind: String) {
        guard nanoseconds > 0 else { return }
        samples.withLock { $0[kind, default: []].append(nanoseconds) }
    }

    /// The deadline, in seconds, for a run of `kind`: `cap` until enough samples, then the observed one within
    /// `minimum...cap`. A run alone (a confirmation or rerun) gets twice the observed deadline.
    func deadline(kind: String, cap: Int, factor: Int, minimum: Int, alone: Bool) -> Int {
        guard let p95 = percentile95(kind: kind) else { return cap }
        let observed = Int(p95 * Int64(factor) / 1_000_000_000) + 2
        return min(cap, max(minimum, alone ? 2 * observed : observed))
    }

    func percentile95(kind: String) -> Int64? {
        samples.withLock { all in
            guard let times = all[kind], times.count >= Self.minimumSamples else { return nil }
            let sorted = times.sorted()
            return sorted[min(sorted.count - 1, (sorted.count * 95 + 99) / 100 - 1)]
        }
    }

    /// One line per run kind that had enough samples, for the run's notes.
    func summary(factor: Int, minimum: Int, cap: Int) -> [String] {
        let kinds = samples.withLock { $0.keys.sorted() }
        return kinds.compactMap { kind in
            guard let p95 = percentile95(kind: kind) else { return nil }
            let deadline = deadline(kind: kind, cap: cap, factor: factor, minimum: minimum, alone: false)
            let label = kind == "tests" ? "narrowed runs" : "runs of \(kind.dropFirst("modules:".count))"
            let count = samples.withLock { $0[kind]?.count ?? 0 }
            return "deadlines from observed times: \(label), 95th percentile "
                + "\((Double(p95) / 1e7).rounded() / 100) s over \(count) runs, deadline \(deadline) s"
        }
    }
}
