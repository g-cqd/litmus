import Foundation
import Synchronization
import Testing

@testable import LitmusCore

/// A `simctl` that keeps its devices in memory and records what it was asked.
private final class FakeSimctl: ProcessExecutor {
    struct Device { var udid: String; var name: String; var state: String }
    struct State {
        var devices: [Device] = []
        var log: [[String]] = []
        var failClone: Int?
        var cloneCount = 0
    }
    let state = Mutex(State())

    func seed(_ name: String, state: String = "Shutdown") -> String {
        let udid = UUID().uuidString
        self.state.withLock { $0.devices.append(Device(udid: udid, name: name, state: state)) }
        return udid
    }
    var devices: [Device] { state.withLock { $0.devices } }
    var log: [[String]] { state.withLock { $0.log } }

    func execute(
        _ command: ToolCommand,
        directory: String,
        environment: [String: String],
        timeout: Int,
        supervision: Supervision
    ) async throws -> ProcessOutput {
        let arguments = Array(command.arguments.dropFirst())
        func out(_ text: String, _ status: Int32 = 0) -> ProcessOutput {
            ProcessOutput(exitStatus: status, stdout: Array(text.utf8), stderr: [], truncated: false, timedOut: false)
        }
        return state.withLock { state in
            state.log.append(arguments)
            switch arguments.first {
            case "clone", "create":
                if arguments.first == "clone" {
                    state.cloneCount += 1
                    if state.failClone == state.cloneCount { return out("", 1) }
                }
                let name = arguments.first == "clone" ? arguments[2] : arguments[1]
                let udid = UUID().uuidString
                state.devices.append(Device(udid: udid, name: name, state: "Shutdown"))
                return out(udid + "\n")
            case "boot":
                if let index = state.devices.firstIndex(where: { $0.udid == arguments[1] }) {
                    state.devices[index].state = "Booted"
                }
                return out("")
            case "shutdown":
                if let index = state.devices.firstIndex(where: { $0.udid == arguments[1] }) {
                    state.devices[index].state = "Shutdown"
                }
                return out("")
            case "delete":
                state.devices.removeAll { $0.udid == arguments[1] }
                return out("")
            case "list":
                let entries = state.devices.map {
                    "{\"udid\":\"\($0.udid)\",\"name\":\"\($0.name)\",\"state\":\"\($0.state)\",\"isAvailable\":true}"
                }
                return out(
                    "{\"devices\":{\"com.apple.CoreSimulator.SimRuntime.iOS-18-2\":[\(entries.joined(separator: ","))]}}"
                )
            default:
                return out("")
            }
        }
    }
}

private func template(_ simulator: FakeSimctl, state: String) -> SimulatorDevice {
    let udid = simulator.seed("iPhone 16", state: state)
    return SimulatorDevice(
        udid: udid,
        name: "iPhone 16",
        runtime: "com.apple.CoreSimulator.SimRuntime.iOS-18-2",
        version: "18.2",
        state: state,
        deviceType: "com.apple.CoreSimulator.SimDeviceType.iPhone-16"
    )
}

private func scratch() throws -> String {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("litmus-pool-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

@Test func `a pool clones a shut-down template, boots every device, and deletes them at its end`() async throws {
    let simctl = FakeSimctl(), root = try scratch()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let model = template(simctl, state: "Shutdown")
    let pool = try await SimulatorPool.create(
        executor: simctl,
        template: model,
        count: 3,
        directory: root,
        registry: root + "/registry"
    )
    #expect(pool.devices.count == 3)
    #expect(simctl.log.filter { $0.first == "clone" }.count == 3)
    #expect(simctl.devices.filter { $0.name.hasPrefix("litmus-") && $0.state == "Booted" }.count == 3)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root + "/registry").count == 1)
    let failures = await pool.teardown()
    #expect(failures.isEmpty)
    #expect(simctl.devices.map(\.name) == ["iPhone 16"], "only the user's own simulator is left")
    #expect(try FileManager.default.contentsOfDirectory(atPath: root + "/registry").isEmpty)
}

@Test func `a booted template is not cloned: new devices of its type are made`() async throws {
    let simctl = FakeSimctl(), root = try scratch()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let model = template(simctl, state: "Booted")
    let pool = try await SimulatorPool.create(
        executor: simctl,
        template: model,
        count: 2,
        directory: root,
        registry: root + "/registry"
    )
    #expect(simctl.log.filter { $0.first == "create" }.count == 2)
    #expect(
        simctl.log.contains { $0.first == "create" && $0.contains("com.apple.CoreSimulator.SimDeviceType.iPhone-16") }
    )
    _ = await pool.teardown()
    #expect(simctl.devices.map(\.name) == ["iPhone 16"])
}

@Test func `a failure while making the pool leaves nothing behind`() async throws {
    let simctl = FakeSimctl(), root = try scratch()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let model = template(simctl, state: "Shutdown")
    simctl.state.withLock { $0.failClone = 2 }
    await #expect(throws: LitmusFailure.self) {
        try await SimulatorPool.create(
            executor: simctl,
            template: model,
            count: 3,
            directory: root,
            registry: root + "/registry"
        )
    }
    #expect(simctl.devices.map(\.name) == ["iPhone 16"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: root + "/registry").isEmpty)
}

@Test func `a pool whose run was killed is deleted by the next run, and nothing else is touched`() async throws {
    let simctl = FakeSimctl(), root = try scratch()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let registry = root + "/registry"
    let model = template(simctl, state: "Shutdown")
    let unrelated = simctl.seed("litmus-someone-elses")
    let orphan = simctl.seed("litmus-DEADBEEF-worker-1")
    let named = simctl.seed("litmus-DEADBEEF-worker-2")
    // The dead run's record: it knew the first device's id, and the second only by name.
    let run = "DEADBEEF-0000-0000-0000-000000000000"
    try FileManager.default.createDirectory(atPath: registry + "/" + run, withIntermediateDirectories: true)
    let record = SimulatorPool<FakeSimctl>.Ownership(
        runID: run,
        names: ["litmus-DEADBEEF-worker-1", "litmus-DEADBEEF-worker-2"],
        udids: [orphan]
    )
    try JSONEncoder().encode(record).write(to: URL(fileURLWithPath: registry + "/" + run + "/ownership.json"))
    // A live run's record, whose lock is held, is left alone.
    let live = "AAAAAAAA-0000-0000-0000-000000000000"
    try FileManager.default.createDirectory(atPath: registry + "/" + live, withIntermediateDirectories: true)
    let held = try WorkspaceLock(path: registry + "/" + live + "/owner.lock")
    defer { held.release() }
    let liveDevice = simctl.seed("litmus-AAAAAAAA-worker-1")
    try JSONEncoder().encode(
        SimulatorPool<FakeSimctl>.Ownership(runID: live, names: ["litmus-AAAAAAAA-worker-1"], udids: [liveDevice])
    ).write(to: URL(fileURLWithPath: registry + "/" + live + "/ownership.json"))

    let pool = try await SimulatorPool.create(
        executor: simctl,
        template: model,
        count: 1,
        directory: root,
        registry: registry
    )
    let remaining = Set(simctl.devices.map(\.udid))
    #expect(!remaining.contains(orphan) && !remaining.contains(named), "the dead run's devices are gone")
    #expect(remaining.contains(unrelated) && remaining.contains(liveDevice) && remaining.contains(model.udid))
    #expect(!FileManager.default.fileExists(atPath: registry + "/" + run))
    #expect(FileManager.default.fileExists(atPath: registry + "/" + live))
    _ = await pool.teardown()
}

@Test func `a fleet lends each device to one run at a time and restarts an owned one after a crash`() async throws {
    let restarted = Mutex<[String]>([])
    let devices = (0..<2).map { PoolDevice(index: $0, udid: "D\($0)", name: "", directory: "/tmp") }
    let fleet = SimulatorFleet(devices: devices, isOwned: true) { device in
        restarted.withLock { $0.append(device.udid) }
    }
    let concurrent = Mutex((now: 0, peak: 0))
    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0..<6 {
            group.addTask {
                try await fleet.withDevice { _ in
                    concurrent.withLock {
                        $0.now += 1
                        $0.peak = max($0.peak, $0.now)
                    }
                    try await Task.sleep(for: .milliseconds(20))
                    concurrent.withLock { $0.now -= 1 }
                    return ((), index == 0)
                }
            }
        }
        try await group.waitForAll()
    }
    #expect(concurrent.withLock { $0.peak } == 2)
    #expect(restarted.withLock { $0.count } == 1)
    let mine = SimulatorFleet.single(udid: "USER", directory: "/tmp")
    _ = try await mine.withDevice { _ in ((), true) }
    #expect(restarted.withLock { $0.count } == 1, "the user's own simulator is never restarted")
}

@Test func `clean deletes orphaned pool simulators, keeps live pools' and the user's own`() async throws {
    let simctl = FakeSimctl(), root = try scratch()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let model = template(simctl, state: "Shutdown")
    let pool = try await SimulatorPool.create(
        executor: simctl,
        template: model,
        count: 1,
        directory: root,
        registry: root + "/registry"
    )
    _ = simctl.seed("litmus-0123abcd-worker-1")
    _ = simctl.seed("litmus-is-not-mine")
    let preview = await Maintenance.cleanSimulators(
        executor: simctl,
        registry: root + "/registry",
        directory: root,
        dryRun: true
    )
    #expect(preview.simulators == ["litmus-0123abcd-worker-1"])
    #expect(simctl.devices.count == 4)
    let cleaned = await Maintenance.cleanSimulators(
        executor: simctl,
        registry: root + "/registry",
        directory: root,
        dryRun: false
    )
    #expect(cleaned.failures.isEmpty)
    #expect(Set(simctl.devices.map(\.name)) == Set(["iPhone 16", "litmus-is-not-mine"] + pool.devices.map(\.name)))
    _ = await pool.teardown()
}
