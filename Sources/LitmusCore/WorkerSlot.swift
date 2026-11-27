internal import Foundation

/// A worker's private directory, from aemi's `ResourcePool`: markers and `TMPDIR` of the runs it hosts live under it.
struct WorkerSlot: Sendable {
    let directory: String

    /// The directory of worker `index` under `root`, created.
    init(root: String, index: Int) throws {
        directory = root + "/worker-\(index)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }
}
