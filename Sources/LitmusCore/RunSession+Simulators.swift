internal import Foundation

extension RunSession {
    /// A simulator named by `name=…,OS=…` becomes the one `id=<UDID>` it denotes, so the build, the tests and the
    /// evidence all name the same device (and the direct simulator harness, which needs the id, can be used).
    func resolveDestination() async throws {
        guard driver.usesXcode, let destination = driver.destination,
            SimulatorInventory.isSimulatorDestination(destination)
        else { return }
        let inventory = try await SimulatorInventory.load(using: executor, directory: root)
        let device = try inventory.resolve(destination)
        resolvedDevice = device
        guard device.destination != destination else { return }
        driver = try driver.with(destination: device.destination)
        resolvedDestinationNote =
            "destination \(destination) resolved to \(device.name), iOS \(device.version), \(device.udid)"
    }

    /// Starts making extra simulators (`--simulators`) when `XcodeHarness` needs them, or boots a shut-down
    /// destination simulator before `SimulatorDirectHarness` probes it.
    func startSimulatorPool(extraSimulators: Bool) {
        guard let device = resolvedDevice else { return }
        if extraSimulators, options.simulators > 1, poolTask == nil {
            let (executor, output, count) = (executor, output, options.simulators)
            poolTask = Task {
                try await SimulatorPool.create(executor: executor, template: device, count: count, directory: output)
            }
        } else if !extraSimulators, device.isShutdown, bootTask == nil {
            let (executor, directory, udid) = (executor, root, device.udid)
            bootTask = Task {
                try? await SimulatorPool.boot(executor, udid: udid, directory: directory, timeout: 300)
            }
        }
    }

    /// The fleet to test on: the simulators made for the run, or nil to use the destination's own.
    func simulatorFleet(notes: inout [String]) async -> SimulatorFleet? {
        if let bootTask {
            await bootTask.value
            self.bootTask = nil
        }
        guard let poolTask else {
            if options.simulators > 1 {
                notes.append(
                    "--simulators \(options.simulators) ignored: the run is not on an iOS Simulator destination"
                )
            }
            return nil
        }
        do {
            let pool = try await poolTask.value
            notes.append(
                "\(pool.devices.count) simulators made for this run and deleted at its end: "
                    + pool.devices.map(\.udid).joined(separator: ", ")
            )
            return pool.fleet
        } catch {
            notes.append("could not make \(options.simulators) simulators (\(error)); using the destination's own")
            self.poolTask = nil
            return nil
        }
    }

    /// Deletes the simulators made for the run. Not cancelled with the run: a stopped run must still clean up.
    func teardownSimulators() async {
        guard let poolTask, !poolTornDown else { return }
        poolTornDown = true
        let failures = await Task.detached { () -> [String] in
            guard let pool = try? await poolTask.value else { return [] }
            return await pool.teardown()
        }.value
        if !failures.isEmpty, artifact != nil {
            artifact.notes.append(
                "simulators left behind (the next run deletes them): " + failures.joined(separator: "; ")
            )
        }
    }
}
