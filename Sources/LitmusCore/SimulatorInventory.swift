internal import Foundation

/// One available simulator, as `simctl list -j devices available` describes it.
public struct SimulatorDevice: Sendable, Equatable {
    public let udid: String
    public let name: String
    /// `com.apple.CoreSimulator.SimRuntime.iOS-18-2`.
    public let runtime: String
    /// `18.2`, from the runtime identifier.
    public let version: String
    public let state: String
    /// `com.apple.CoreSimulator.SimDeviceType.iPhone-16`, when the listing names it.
    public let deviceType: String?

    public var isShutdown: Bool { state == "Shutdown" }
    /// The destination every build and test of a run uses once the device is chosen.
    public var destination: String { "platform=iOS Simulator,id=\(udid)" }
}

/// The simulators `simctl` lists, and how an Xcode destination string picks one of them.
public struct SimulatorInventory: Sendable, Equatable {
    public let devices: [SimulatorDevice]

    public init(devices: [SimulatorDevice]) { self.devices = devices }

    /// Reads `simctl list -j devices available`; only iOS runtimes and available devices are kept.
    public init(json: [UInt8]) throws {
        struct Listing: Decodable {
            struct Entry: Decodable {
                let udid: String
                let name: String
                let state: String?
                let isAvailable: Bool?
                let deviceTypeIdentifier: String?
            }
            let devices: [String: [Entry]]
        }
        let listing: Listing
        do { listing = try JSONDecoder().decode(Listing.self, from: Data(json)) } catch {
            throw LitmusFailure("simctl listing is not readable: \(error)")
        }
        var found: [SimulatorDevice] = []
        for (runtime, entries) in listing.devices {
            guard let version = Self.iOSVersion(of: runtime) else { continue }
            for entry in entries where entry.isAvailable != false {
                found.append(
                    SimulatorDevice(
                        udid: entry.udid,
                        name: entry.name,
                        runtime: runtime,
                        version: version,
                        state: entry.state ?? "Shutdown",
                        deviceType: entry.deviceTypeIdentifier
                    )
                )
            }
        }
        devices = found.sorted { ($0.name, $0.version, $0.udid) < ($1.name, $1.version, $1.udid) }
    }

    /// `18.2` for `com.apple.CoreSimulator.SimRuntime.iOS-18-2`; nil for other platforms.
    static func iOSVersion(of runtime: String) -> String? {
        guard let range = runtime.range(of: ".SimRuntime.iOS-") else { return nil }
        let parts = runtime[range.upperBound...].split(separator: "-")
        guard !parts.isEmpty, parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        return parts.joined(separator: ".")
    }

    /// Orders dotted versions numerically (`18.10` after `18.2`).
    static func newer(_ lhs: String, than rhs: String) -> Bool {
        lhs.compare(rhs, options: .numeric) == .orderedDescending
    }

    /// The fields of an Xcode destination (`platform=iOS Simulator,name=iPhone 16,OS=18.2`); nil when a field repeats
    /// or has no value.
    static func fields(of destination: String) -> [String: String]? {
        var fields: [String: String] = [:]
        for part in destination.split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, !pair[0].isEmpty, !pair[1].isEmpty, fields[pair[0]] == nil else { return nil }
            fields[pair[0]] = pair[1]
        }
        return fields
    }

    /// Whether `destination` names an iOS Simulator at all.
    public static func isSimulatorDestination(_ destination: String) -> Bool {
        guard let fields = fields(of: destination) else { return destination.contains("iOS Simulator") }
        return fields["platform"] == "iOS Simulator"
    }

    /// The one simulator `destination` names: by `id`, or by `name` with an `OS` (a version, a version prefix, or
    /// `latest`; the default). Several simulators of one name on one runtime are an error, never a guess.
    public func resolve(_ destination: String) throws -> SimulatorDevice {
        guard let fields = Self.fields(of: destination), fields["platform"] == "iOS Simulator" else {
            throw LitmusFailure("destination is not a concrete iOS Simulator: \(destination)")
        }
        if let id = fields["id"] {
            guard let device = devices.first(where: { $0.udid.caseInsensitiveCompare(id) == .orderedSame }) else {
                // An Xcode upgrade replaces runtimes and their devices: say what there is now.
                throw LitmusFailure("no available iOS Simulator has id \(id); available: \(availableList)")
            }
            return device
        }
        guard let name = fields["name"] else {
            throw LitmusFailure(
                "destination \(destination) names no simulator: give id=<UDID>, or name=<device name>[,OS=<version>]"
            )
        }
        let named = devices.filter { $0.name == name }
        guard !named.isEmpty else {
            throw LitmusFailure("no available iOS Simulator is named \(name); available: \(availableList)")
        }
        let os = fields["OS"] ?? "latest"
        let versions = Set(named.map(\.version))
        let chosen: String
        if os == "latest" {
            guard let latest = versions.sorted(by: Self.newer).first else { throw LitmusFailure("no runtime") }
            chosen = latest
        } else if versions.contains(os) {
            chosen = os
        } else if let prefix = versions.filter({ $0.hasPrefix(os + ".") }).sorted(by: Self.newer).first {
            chosen = prefix
        } else {
            throw LitmusFailure(
                "no iOS Simulator named \(name) runs iOS \(os); it runs \(versions.sorted(by: Self.newer).joined(separator: ", "))"
            )
        }
        let matches = named.filter { $0.version == chosen }
        guard matches.count == 1, let device = matches.first else {
            throw LitmusFailure(
                "\(matches.count) simulators are named \(name) on iOS \(chosen) (\(matches.map(\.udid).joined(separator: ", "))); give id=<UDID>"
            )
        }
        return device
    }

    /// The available simulators for an error message: name, iOS version and id, newest runtime first, at most 12.
    var availableList: String {
        guard !devices.isEmpty else { return "none (install an iOS Simulator runtime in Xcode)" }
        let sorted = devices.sorted { lhs, rhs in
            lhs.version != rhs.version
                ? Self.newer(lhs.version, than: rhs.version) : lhs.name.lowercased() < rhs.name.lowercased()
        }
        let shown = sorted.prefix(12).map { "\($0.name) (iOS \($0.version), id=\($0.udid))" }
        return shown.joined(separator: "; ") + (sorted.count > 12 ? "; and \(sorted.count - 12) more" : "")
    }

    /// Lists the simulators through `executor`.
    public static func load<Executor: ProcessExecutor>(using executor: Executor, directory: String) async throws -> Self
    {
        let output = try await executor.execute(
            ToolCommand(executable: "/usr/bin/xcrun", arguments: ["simctl", "list", "-j", "devices", "available"]),
            directory: directory,
            environment: subjectEnvironment(nil),
            timeout: 60
        )
        guard output.exitStatus == 0, !output.timedOut, !output.truncated else {
            throw LitmusFailure("`simctl list` failed (exit \(output.exitStatus))")
        }
        return try Self(json: output.stdout)
    }
}
