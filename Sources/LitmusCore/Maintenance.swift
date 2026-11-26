internal import Foundation

/// `litmus clean`: what interrupted or finished runs leave behind, removed without touching anything Litmus did not
/// make.
public enum Maintenance {
    /// What a clean removed, or would remove with a dry run.
    public struct Cleaned: Sendable, Equatable {
        /// Simulators deleted, by name.
        public var simulators: [String] = []
        /// Run directories' workspaces, build products and worker directories removed.
        public var directories: [String] = []
        public var freedBytes: Int64 = 0
        public var failures: [String] = []
    }

    /// Deletes the simulators of pools whose run is gone (their registry lock is free), then any device named like a
    /// pool's (`litmus-<run>-worker-<n>`) that no live pool owns: one made by a run killed before it was recorded.
    public static func cleanSimulators<Executor: ProcessExecutor>(
        executor: Executor,
        registry: String = SimulatorPool<Executor>.defaultRegistry,
        directory: String,
        dryRun: Bool
    ) async -> Cleaned {
        var cleaned = Cleaned()
        let live = SimulatorPool<Executor>.liveNames(registry: registry)
        guard
            let listing = try? await SimulatorPool<Executor>.simctl(
                executor,
                ["list", "-j", "devices"],
                directory: directory,
                timeout: 60
            ),
            listing.exitStatus == 0,
            let object = try? JSONSerialization.jsonObject(with: Data(listing.stdout)) as? [String: Any],
            let groups = object["devices"] as? [String: [[String: Any]]]
        else {
            cleaned.failures.append("simctl list failed: simulators not cleaned")
            return cleaned
        }
        let orphans = groups.values.joined().compactMap { entry -> (name: String, udid: String)? in
            guard let name = entry["name"] as? String, let udid = entry["udid"] as? String,
                isPoolDeviceName(name), !live.contains(name)
            else { return nil }
            return (name, udid)
        }
        cleaned.simulators = orphans.map(\.name).sorted()
        guard !dryRun else { return cleaned }
        cleaned.failures += await SimulatorPool<Executor>.recoverStale(
            executor: executor,
            registry: registry,
            directory: directory
        )
        for orphan in orphans {
            _ = try? await SimulatorPool<Executor>.simctl(
                executor,
                ["shutdown", orphan.udid],
                directory: directory,
                timeout: 30
            )
            let deleted = try? await SimulatorPool<Executor>.simctl(
                executor,
                ["delete", orphan.udid],
                directory: directory,
                timeout: 60
            )
            if deleted?.exitStatus != 0 { cleaned.failures.append("could not delete simulator \(orphan.udid)") }
        }
        return cleaned
    }

    /// `litmus-<8 characters>-worker-<number>`, the only names a pool gives its devices.
    static func isPoolDeviceName(_ name: String) -> Bool {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        return parts.count == 4 && parts[0] == "litmus" && parts[1].count == 8 && parts[2] == "worker"
            && !parts[3].isEmpty && parts[3].allSatisfy(\.isNumber)
    }

    /// Removes the workspace copy, build products and worker directories of each finished run directory in `runs`,
    /// keeping its evidence (`run.json`, `run.pb`, journal, logs). A directory without `run.json`, or whose run is not
    /// complete, is left alone and named in the failures.
    public static func cleanRuns(_ runs: [String], dryRun: Bool) -> Cleaned {
        var cleaned = Cleaned()
        let fm = FileManager.default
        for run in runs {
            guard let artifact = try? ArtifactCodec.read(RunArtifact.self, path: run + "/run.json"), artifact.complete
            else {
                cleaned.failures.append("\(run): not a finished run directory (no complete run.json); left alone")
                continue
            }
            for name in ["workspace", "artifacts", "workers"] {
                let path = run + "/" + name
                guard fm.fileExists(atPath: path) else { continue }
                cleaned.freedBytes += size(of: path)
                cleaned.directories.append(path)
                if !dryRun {
                    do { try fm.removeItem(atPath: path) } catch {
                        cleaned.failures.append("could not remove \(path): \(error)")
                    }
                }
            }
        }
        return cleaned
    }

    /// The allocated size of the regular files under `path`, links not followed.
    static func size(of path: String) -> Int64 {
        guard let walk = FileManager.default.enumerator(atPath: path) else { return 0 }
        var total: Int64 = 0
        while let relative = walk.nextObject() as? String {
            let attributes = try? FileManager.default.attributesOfItem(atPath: path + "/" + relative)
            guard attributes?[.type] as? FileAttributeType == .typeRegular else { continue }
            total += (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }
        return total
    }
}

extension SimulatorPool {
    /// The device names of every registered pool whose run is alive (its lock is held).
    static func liveNames(registry: String) -> Set<String> {
        let fm = FileManager.default
        var names: Set<String> = []
        for run in (try? fm.contentsOfDirectory(atPath: registry)) ?? [] {
            let entry = registry + "/" + run
            if let free = try? WorkspaceLock(path: entry + "/owner.lock") {
                free.release()
                continue
            }
            guard let bytes = fm.contents(atPath: entry + "/ownership.json"),
                let ownership = try? JSONDecoder().decode(Ownership.self, from: bytes)
            else { continue }
            names.formUnion(ownership.names)
        }
        return names
    }
}
