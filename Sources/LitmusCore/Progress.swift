internal import Foundation
internal import Synchronization

/// One line per decided mutant, as the run goes: `[12/80] killed  Sources/A.swift:7 replace-logical`.
final class ProgressReporter: Sendable {
    private let done = Mutex(0)
    private let total: Int
    private let write: @Sendable (String) -> Void

    init(total: Int, write: @escaping @Sendable (String) -> Void) {
        self.total = total
        self.write = write
    }

    /// A reporter that writes to standard error.
    static func standardError(total: Int) -> ProgressReporter {
        ProgressReporter(total: total) { line in FileHandle.standardError.write(Data((line + "\n").utf8)) }
    }

    func report(_ result: MutationResult) {
        let count = done.withLock {
            $0 += 1
            return $0
        }
        let width = String(total).count
        let number = String(count)
        let verdict = result.verdict.rawValue
        let site = result.mutation
        write(
            "litmus: [\(String(repeating: " ", count: max(0, width - number.count)))\(number)/\(total)] "
                + "\(verdict.padding(toLength: 19, withPad: " ", startingAt: 0)) "
                + "\(site.path):\(site.line) \(site.operatorID.rawValue)"
                + (result.reusedFrom == nil ? "" : " (reused)")
        )
    }
}
