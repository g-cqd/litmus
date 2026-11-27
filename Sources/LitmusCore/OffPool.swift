internal import Foundation

/// Runs blocking `work` (a `poll`, a FIFO open or read) on a GCD thread, off Swift's cooperative pool. The pool has
/// one thread per core; a task that blocks one for as long as a test runs leaves deadlines, monitors and stops waiting
/// for a thread, and with as many blocked readers as cores, nothing else runs.
func offPool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(returning: work()) }
    }
}
