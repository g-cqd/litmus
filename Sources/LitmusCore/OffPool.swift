internal import Foundation

/// Runs blocking `work` (a `poll`, a FIFO open or read) on a GCD thread, off Swift's cooperative pool. The pool has
/// one thread per core; a task that blocks one for as long as a test runs leaves deadlines, monitors and stops waiting
/// for a thread, and with as many blocked readers as cores, nothing else runs.
///
/// Not AemiRuntime's `BlockingOffloadPool`: its threads are a fixed number, and these calls block for a whole test run,
/// a drainer and a reader per worker, so a pool narrower than the run's workers would leave some waiting for a thread
/// that never frees. GCD's global queue adds threads for work that blocks.
func offPool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(returning: work()) }
    }
}
