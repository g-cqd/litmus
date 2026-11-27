internal import Foundation

extension MutationRunner {
    /// The harness for this subject: Xcode for schemes, direct bundles when SwiftPM's layout is understood, else
    /// `swift test`. Every fallback is written to the run's notes.
    func makeHarness(
        driver: BuildDriver,
        options: RunOptions,
        workspace: String,
        artifacts: String,
        logs: String,
        fleet: SimulatorFleet? = nil,
        notes: inout [String]
    ) async throws -> any TestHarness {
        if driver.usesXcode {
            try XcodeTestConfiguration.validateArtifacts(artifacts: artifacts, driver: driver)
            let xcode = XcodeHarness(
                executor: executor,
                driver: driver,
                workspace: workspace,
                artifacts: artifacts,
                logs: logs,
                fleet: fleet,
                keepResultBundles: options.keepResultBundles
            )
            guard options.simulatorHarness, let destination = driver.destination,
                let udid = SimulatorDirectHarness<Executor>.simulatorID(destination)
            else { return xcode }
            guard !driver.xcodebuildArgumentsSelectTests else {
                notes.append(
                    "simulator helper not used: --xcodebuild-argument selects tests (-only-testing, -skip-testing or test configurations), which only xcodebuild honours"
                )
                return xcode
            }
            do {
                return try await simulatorHarness(
                    udid: udid,
                    fleet: fleet ?? .single(udid: udid, directory: workspace),
                    workers: options.jobs,
                    workspace: driver.executionDirectory(workspace: workspace),
                    artifacts: artifacts,
                    logs: logs,
                    notes: &notes
                ) ?? xcode
            } catch {
                notes.append("simulator helper unavailable (\(error)); using xcodebuild")
                return xcode
            }
        }
        let fallback = SwiftPMToolHarness(
            executor: executor,
            driver: driver,
            workspace: workspace,
            artifacts: artifacts,
            logs: logs
        )
        guard options.harness == .automatic else { return fallback }
        func query(_ arguments: [String]) async throws -> String? {
            let output = try await executor.execute(
                ToolCommand(executable: "/usr/bin/xcrun", arguments: arguments),
                directory: driver.executionDirectory(workspace: workspace),
                environment: subjectEnvironment(nil),
                timeout: 120
            )
            guard output.exitStatus == 0, !output.truncated, !output.timedOut else { return nil }
            return String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let package = driver.swiftPMArguments(workspace: workspace, artifacts: artifacts)
        guard let binPath = try await query(["swift", "build", "--show-bin-path"] + package),
            let listing = try await query(["swift", "test", "list", "--skip-build"] + package),
            let xctest = try await query(["--find", "xctest"]),
            let swift = try await query(["--find", "swift"]),
            let platform = try await query(["--sdk", "macosx", "--show-sdk-platform-path"])
        else {
            notes.append("direct test bundles unavailable (toolchain query failed); using swift test, one worker")
            return fallback
        }
        let helper = URL(fileURLWithPath: swift).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("libexec/swift/pm/swiftpm-testing-helper").path
        guard FileManager.default.isExecutableFile(atPath: helper), xctest.hasPrefix("/"),
            let bundles = SwiftPMDirectHarness<Executor>.bundles(listing: listing, binPath: binPath)
        else {
            notes.append("direct test bundles unavailable (layout not understood); using swift test, one worker")
            return fallback
        }
        let direct = SwiftPMDirectHarness(
            executor: executor,
            bundles: bundles,
            toolchain: .init(
                xctest: xctest,
                testingHelper: helper,
                frameworks: platform + "/Developer/Library/Frameworks",
                libraries: platform + "/Developer/usr/lib"
            ),
            workspace: driver.executionDirectory(workspace: workspace),
            logs: logs,
            workers: options.jobs
        )
        guard options.sharedProcess != .off, bundles.contains(where: { $0.swiftTestingCount > 0 }) else {
            return direct
        }
        let scratch = artifacts + "/shared-process"
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        let build: @Sendable () async throws -> String = { [executor, artifacts, logs] in
            try await MacOSHelper.build(into: artifacts, executor: executor, logs: logs)
        }
        if options.sharedProcess == .on {
            // Always: a helper that does not build fails the run now, not mutant by mutant.
            _ = try await build()
            notes.append(
                "shared process: kills of narrowed Swift Testing runs are decided in helper processes that keep the "
                    + "test bundle loaded; survivors and everything else run in fresh processes"
            )
        }
        return SharedProcessHarness(
            direct: direct,
            helper: build,
            scratch: scratch,
            token: options.environmentToken,
            mode: options.sharedProcess
        )
    }

    /// Writes one batch's schemas into the snapshot, keeping the originals to restore.
    /// The direct simulator harness when every test target is hostless and the helper runs on the booted simulator
    ///; nil, with a note, to use `xcodebuild`.
    func simulatorHarness(
        udid: String,
        fleet: SimulatorFleet,
        workers: Int,
        workspace: String,
        artifacts: String,
        logs: String,
        notes: inout [String]
    ) async throws -> (any TestHarness)? {
        let products = artifacts + "/DerivedData/Build/Products"
        let runs = try FileManager.default.contentsOfDirectory(atPath: products).filter { $0.hasSuffix(".xctestrun") }
        guard runs.count == 1, let run = runs.first else {
            notes.append("simulator helper not used: \(runs.count) .xctestrun files; using xcodebuild")
            return nil
        }
        let helper = try await SimulatorHelper.build(into: artifacts, executor: executor, logs: logs)
        let targets = try XCTestRunTarget.targets(
            xctestrun: products + "/" + run,
            products: products,
            platforms: helper.platforms
        )
        guard let bundles = SimulatorDirectHarness<Executor>.bundles(targets) else {
            notes.append("simulator helper not used: a test target is a UI test")
            return nil
        }
        // `simctl spawn` needs a booted device; xcodebuild boots it itself.
        let boot = try await executor.execute(
            ToolCommand(executable: "/usr/bin/xcrun", arguments: ["simctl", "bootstatus", udid, "-b"]),
            directory: workspace,
            environment: subjectEnvironment(nil),
            timeout: 600
        )
        guard boot.exitStatus == 0 else {
            notes.append("simulator helper not used: \(udid) did not boot; using xcodebuild")
            return nil
        }
        let direct = SimulatorDirectHarness(
            executor: executor,
            fleet: fleet,
            bundles: bundles,
            helper: helper,
            workspace: workspace,
            logs: logs,
            workers: workers
        )
        guard try await direct.probe() else {
            notes.append("simulator helper not used: its probe failed (logs/simulator-probe.log); using xcodebuild")
            return nil
        }
        let kindLabel = direct.hasAppHostedTargets ? "app-hosted unit test bundles" : "hostless test bundles"
        notes.append(
            "\(kindLabel) run on simulator \(udid) through Litmus's helper: \(bundles.map(\.module).joined(separator: ", "))"
        )
        return direct
    }
}
