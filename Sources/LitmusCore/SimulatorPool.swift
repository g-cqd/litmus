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

/// Simulators made for one run, recorded in a registry outside the run so that a run killed without cleanup does not
/// leave them behind: the next run finds the record, sees its owner gone, and deletes exactly the devices it names.
public final class SimulatorPool<Executor: ProcessExecutor>: Sendable {
    struct Ownership: Codable, Equatable {
        var runID: String
        var names: [String]
        var udids: [String]
    }

    public let devices: [PoolDevice]
    private let executor: Executor
    private let directory: String
    private let registry: String
    private let ownership: Ownership
    private let lock: WorkspaceLock

    /// Where registries live unless a test says otherwise.
    public static var defaultRegistry: String {
        let support =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path
            ?? NSHomeDirectory() + "/Library/Application Support"
        return support + "/litmus/simulator-pools"
    }

    static func prefix(_ runID: String) -> String { "litmus-\(runID.prefix(8))-worker-" }

    /// Makes `count` simulators like `template` (clones when it is shut down, new devices of its type otherwise),
    /// boots them together, and records them. Stale pools of dead runs are removed first.
    public static func create(
        executor: Executor,
        template: SimulatorDevice,
        count: Int,
        directory: String,
        registry: String = defaultRegistry,
        bootTimeout: Int = 300
    ) async throws -> SimulatorPool {
        guard count >= 1 else { throw LitmusFailure("a simulator pool needs at least one device") }
        try FileManager.default.createDirectory(atPath: registry, withIntermediateDirectories: true)
        _ = await recoverStale(executor: executor, registry: registry, directory: directory)
        let runID = UUID().uuidString
        let entry = registry + "/" + runID
        try FileManager.default.createDirectory(atPath: entry, withIntermediateDirectories: true)
        let lock = try WorkspaceLock(path: entry + "/owner.lock")
        let names = (1...count).map { prefix(runID) + String($0) }
        // The names are on disk before any device exists: a device made just before a kill is still found by name.
        var ownership = Ownership(runID: runID, names: names, udids: [])
        try write(ownership, in: entry)
        do {
            let created = try await withThrowingTaskGroup(of: (Int, String).self) { group in
                for (index, name) in names.enumerated() {
                    group.addTask {
                        let arguments =
                            template.isShutdown
                            ? ["clone", template.udid, name]
                            : ["create", name, template.deviceType ?? "", template.runtime]
                        guard template.isShutdown || template.deviceType != nil else {
                            throw LitmusFailure("the template simulator names no device type; cannot make a new one")
                        }
                        let output = try await simctl(executor, arguments, directory: directory, timeout: 120)
                        let udid = String(decoding: output.stdout, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard output.exitStatus == 0, UUID(uuidString: udid) != nil else {
                            throw LitmusFailure("`simctl \(arguments[0])` for \(name) failed: \(udid.prefix(200))")
                        }
                        return (index, udid)
                    }
                }
                var found: [(Int, String)] = []
                for try await item in group { found.append(item) }
                return found.sorted { $0.0 < $1.0 }
            }
            ownership.udids = created.map(\.1)
            try write(ownership, in: entry)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (_, udid) in created {
                    group.addTask { try await boot(executor, udid: udid, directory: directory, timeout: bootTimeout) }
                }
                try await group.waitForAll()
            }
            let devices = created.map { index, udid in
                PoolDevice(
                    index: index,
                    udid: udid,
                    name: names[index],
                    directory: directory + "/workers/simulator-\(index + 1)"
                )
            }
            return SimulatorPool(
                devices: devices,
                executor: executor,
                directory: directory,
                registry: registry,
                ownership: ownership,
                lock: lock
            )
        } catch {
            _ = await remove(ownership, executor: executor, directory: directory)
            try? FileManager.default.removeItem(atPath: entry)
            lock.release()
            throw error
        }
    }

    private init(
        devices: [PoolDevice],
        executor: Executor,
        directory: String,
        registry: String,
        ownership: Ownership,
        lock: WorkspaceLock
    ) {
        self.devices = devices
        self.executor = executor
        self.directory = directory
        self.registry = registry
        self.ownership = ownership
        self.lock = lock
    }

    /// The devices as a fleet whose members are restarted after a crash or a timeout.
    public var fleet: SimulatorFleet {
        let executor = executor, directory = directory
        return SimulatorFleet(
            devices: devices,
            isOwned: true,
            restart: { device in
                _ = try? await Self.simctl(executor, ["shutdown", device.udid], directory: directory, timeout: 30)
                try? await Self.boot(executor, udid: device.udid, directory: directory, timeout: 300)
            }
        )
    }

    /// Shuts down and deletes every device of the pool, removes its record, and releases it. Returns what could not
    /// be done; the record stays then, so a later run retries.
    public func teardown() async -> [String] {
        let failures = await Self.remove(ownership, executor: executor, directory: directory)
        if failures.isEmpty { try? FileManager.default.removeItem(atPath: registry + "/" + ownership.runID) }
        lock.release()
        return failures
    }

    // MARK: Recovery

    /// Deletes the devices of every registered pool whose owner is gone (its lock is free). Returns the failures.
    @discardableResult
    static func recoverStale(executor: Executor, registry: String, directory: String) async -> [String] {
        let fm = FileManager.default
        var failures: [String] = []
        for run in (try? fm.contentsOfDirectory(atPath: registry)) ?? [] {
            let entry = registry + "/" + run
            guard let held = try? WorkspaceLock(path: entry + "/owner.lock") else { continue }  // owner alive
            defer { held.release() }
            guard let bytes = fm.contents(atPath: entry + "/ownership.json"),
                let ownership = try? JSONDecoder().decode(Ownership.self, from: bytes), ownership.runID == run
            else {
                try? fm.removeItem(atPath: entry)
                continue
            }
            let problems = await remove(ownership, executor: executor, directory: directory)
            if problems.isEmpty { try? fm.removeItem(atPath: entry) } else { failures += problems }
        }
        return failures
    }

    /// Deletes the devices `ownership` names: by id when recorded, and any device carrying one of its exact names
    /// (one made just before the id was written). Nothing else is ever touched.
    static func remove(_ ownership: Ownership, executor: Executor, directory: String) async -> [String] {
        var targets = Set(ownership.udids)
        if let listing = try? await simctl(executor, ["list", "-j", "devices"], directory: directory, timeout: 60),
            listing.exitStatus == 0,
            let object = try? JSONSerialization.jsonObject(with: Data(listing.stdout)) as? [String: Any],
            let groups = object["devices"] as? [String: [[String: Any]]]
        {
            let owned = Set(ownership.names)
            for entry in groups.values.joined() {
                if let name = entry["name"] as? String, owned.contains(name), let udid = entry["udid"] as? String {
                    targets.insert(udid)
                }
            }
        }
        var failures: [String] = []
        for udid in targets.sorted() {
            _ = try? await simctl(executor, ["shutdown", udid], directory: directory, timeout: 30)
            let deleted = try? await simctl(executor, ["delete", udid], directory: directory, timeout: 60)
            if deleted?.exitStatus != 0 { failures.append("could not delete simulator \(udid)") }
        }
        return failures
    }

    // MARK: simctl

    static func simctl(_ executor: Executor, _ arguments: [String], directory: String, timeout: Int) async throws
        -> ProcessOutput
    {
        try await executor.execute(
            ToolCommand(executable: "/usr/bin/xcrun", arguments: ["simctl"] + arguments),
            directory: directory,
            environment: subjectEnvironment(nil),
            timeout: timeout
        )
    }

    static func boot(_ executor: Executor, udid: String, directory: String, timeout: Int) async throws {
        let started = try await simctl(executor, ["boot", udid], directory: directory, timeout: 60)
        // Already booted is fine.
        guard
            started.exitStatus == 0 || String(decoding: started.stderr, as: UTF8.self).contains("current state: Booted")
        else { throw LitmusFailure("`simctl boot \(udid)` failed (exit \(started.exitStatus))") }
        let ready = try await simctl(executor, ["bootstatus", udid, "-b"], directory: directory, timeout: timeout)
        guard ready.exitStatus == 0, !ready.timedOut else {
            throw LitmusFailure("simulator \(udid) did not finish booting in \(timeout) s")
        }
    }

    private static func write(_ ownership: Ownership, in entry: String) throws {
        let data = try JSONEncoder().encode(ownership)
        try data.write(to: URL(fileURLWithPath: entry + "/ownership.json"), options: .atomic)
    }
}
