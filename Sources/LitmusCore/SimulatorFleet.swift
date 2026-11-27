internal import Foundation

/// One simulator a run may use, and the directory it owns for per-worker files.
public struct PoolDevice: Sendable, Equatable {
    public let index: Int
    public let udid: String
    public let name: String
    public let directory: String
    /// The destination a build or test of this worker names.
    public var destination: String { "platform=iOS Simulator,id=\(udid)" }
}

/// Lends each device to one run at a time; further runs wait for a release.
actor DeviceLeases {
    private let all: [PoolDevice]
    private var free: [PoolDevice]
    private var waiters: [CheckedContinuation<PoolDevice, Never>] = []
    private var cursor = 0
    let count: Int

    init(_ devices: [PoolDevice]) {
        all = devices
        free = devices
        count = devices.count
    }

    func acquire() async -> PoolDevice {
        if !free.isEmpty { return free.removeFirst() }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func release(_ device: PoolDevice) {
        if waiters.isEmpty { free.append(device) } else { waiters.removeFirst().resume(returning: device) }
    }

    func next() -> PoolDevice {
        let picked = all[cursor % max(1, all.count)]
        cursor = (cursor + 1) % max(1, all.count)
        return picked
    }
}

/// The simulators a run's tests use: one the user chose (never shut down or erased by Litmus), or several Litmus made.
public struct SimulatorFleet: Sendable {
    let leases: DeviceLeases
    public let count: Int
    /// Whether Litmus made these devices, and so may restart them after a crash or a timeout.
    public let isOwned: Bool
    private let restart: @Sendable (PoolDevice) async -> Void

    /// The user's own simulator: one worker, never restarted.
    public static func single(udid: String, directory: String) -> SimulatorFleet {
        SimulatorFleet(
            devices: [PoolDevice(index: 0, udid: udid, name: "", directory: directory)],
            isOwned: false,
            restart: { _ in }
        )
    }

    init(devices: [PoolDevice], isOwned: Bool, restart: @escaping @Sendable (PoolDevice) async -> Void) {
        leases = DeviceLeases(devices)
        count = devices.count
        self.isOwned = isOwned
        self.restart = restart
    }

    /// Picks a simulator round-robin without taking an exclusive lease: safe for `simctl spawn`, where each run is
    /// an independent process with its own temporary and marker directories.
    func nextDevice() async -> PoolDevice { await leases.next() }

    /// Runs `body` on a free device; a device that crashed or timed out is restarted before it is lent again.
    func withDevice<T: Sendable>(
        _ body: @Sendable (PoolDevice) async throws -> (value: T, needsRestart: Bool)
    ) async throws -> T {
        let device = await leases.acquire()
        do {
            let (value, needsRestart) = try await body(device)
            if needsRestart && isOwned { await restart(device) }
            await leases.release(device)
            return value
        } catch {
            if isOwned { await restart(device) }
            await leases.release(device)
            throw error
        }
    }
}
