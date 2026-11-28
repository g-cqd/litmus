internal import Foundation

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
        // The template's state now, not when the destination was resolved: the helper may have booted it since, and
        // a booted simulator cannot be cloned (or clones mid-boot into a device tests never attach to).
        let shutDown = await isShutDown(executor, udid: template.udid, directory: directory) ?? template.isShutdown
        do {
            let created = try await withThrowingTaskGroup(of: (Int, String).self) { group in
                for (index, name) in names.enumerated() {
                    group.addTask {
                        let arguments =
                            shutDown
                            ? ["clone", template.udid, name]
                            : ["create", name, template.deviceType ?? "", template.runtime]
                        guard shutDown || template.deviceType != nil else {
                            throw LitmusFailure("the template simulator names no device type; cannot make a new one")
                        }
                        let output = try await simctl(executor, arguments, directory: directory, timeout: 120)
                        let udid = String(decoding: output.stdout, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard output.exitStatus == 0, UUID(uuidString: udid) != nil else {
                            let error = String(decoding: output.stderr, as: UTF8.self)
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            throw LitmusFailure(
                                "`simctl \(arguments[0])` for \(name) failed: \((error.isEmpty ? udid : error).prefix(200))"
                            )
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
        let owned = Set(ownership.names)
        for device in await listedDevices(executor, directory: directory) ?? [] where owned.contains(device.name) {
            targets.insert(device.udid)
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

    /// Every device `simctl` lists, as its JSON entry; nil when the listing fails.
    static func deviceEntries(_ executor: Executor, directory: String) async -> [[String: Any]]? {
        guard let listing = try? await simctl(executor, ["list", "-j", "devices"], directory: directory, timeout: 60),
            listing.exitStatus == 0,
            let object = try? JSONSerialization.jsonObject(with: Data(listing.stdout)) as? [String: Any],
            let groups = object["devices"] as? [String: [[String: Any]]]
        else { return nil }
        return Array(groups.values.joined())
    }

    /// Every device `simctl` lists, by name and id; nil when the listing fails.
    static func listedDevices(_ executor: Executor, directory: String) async -> [(name: String, udid: String)]? {
        await deviceEntries(executor, directory: directory)?.compactMap { entry in
            guard let name = entry["name"] as? String, let udid = entry["udid"] as? String else { return nil }
            return (name, udid)
        }
    }

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

    /// Whether simulator `udid` is shut down now; nil when `simctl` cannot say.
    static func isShutDown(_ executor: Executor, udid: String, directory: String) async -> Bool? {
        guard
            let device = await deviceEntries(executor, directory: directory)?.first(where: {
                $0["udid"] as? String == udid
            })
        else { return nil }
        return (device["state"] as? String) == "Shutdown"
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
