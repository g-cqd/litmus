import Foundation
import Testing

@testable import LitmusCore

private let listing = """
    {"devices": {
      "com.apple.CoreSimulator.SimRuntime.iOS-17-5": [
        {"udid": "11111111-1111-1111-1111-111111111111", "name": "iPhone 15", "state": "Shutdown", "isAvailable": true,
         "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-15"}
      ],
      "com.apple.CoreSimulator.SimRuntime.iOS-18-2": [
        {"udid": "22222222-2222-2222-2222-222222222222", "name": "iPhone 16", "state": "Booted", "isAvailable": true},
        {"udid": "33333333-3333-3333-3333-333333333333", "name": "iPhone 15", "state": "Shutdown", "isAvailable": true},
        {"udid": "44444444-4444-4444-4444-444444444444", "name": "iPad Air", "state": "Shutdown", "isAvailable": false}
      ],
      "com.apple.CoreSimulator.SimRuntime.iOS-18-10": [
        {"udid": "55555555-5555-5555-5555-555555555555", "name": "iPhone 15", "state": "Shutdown", "isAvailable": true},
        {"udid": "66666666-6666-6666-6666-666666666666", "name": "Twin", "state": "Shutdown", "isAvailable": true},
        {"udid": "77777777-7777-7777-7777-777777777777", "name": "Twin", "state": "Shutdown", "isAvailable": true}
      ],
      "com.apple.CoreSimulator.SimRuntime.watchOS-11-0": [
        {"udid": "88888888-8888-8888-8888-888888888888", "name": "Watch", "state": "Shutdown", "isAvailable": true}
      ]
    }}
    """

private func inventory() throws -> SimulatorInventory { try SimulatorInventory(json: Array(listing.utf8)) }

@Test func `the listing keeps available iOS devices and reads their versions`() throws {
    let found = try inventory().devices
    #expect(found.count == 6)
    #expect(!found.contains { $0.name == "Watch" || $0.name == "iPad Air" })
    #expect(found.first { $0.udid.hasPrefix("5555") }?.version == "18.10")
    #expect(found.first { $0.udid.hasPrefix("2222") }?.state == "Booted")
    #expect(throws: LitmusFailure.self) { try SimulatorInventory(json: Array("not json".utf8)) }
}

@Test func `a name resolves to the latest runtime, numerically, unless an OS is given`() throws {
    let inventory = try inventory()
    #expect(try inventory.resolve("platform=iOS Simulator,name=iPhone 15").udid.hasPrefix("5555"))
    #expect(try inventory.resolve("platform=iOS Simulator,name=iPhone 15,OS=latest").udid.hasPrefix("5555"))
    #expect(try inventory.resolve("platform=iOS Simulator,name=iPhone 15,OS=18.2").udid.hasPrefix("3333"))
    #expect(try inventory.resolve("platform=iOS Simulator,name=iPhone 15,OS=17").udid.hasPrefix("1111"))
    #expect(try inventory.resolve("platform=iOS Simulator,name=iPhone 16").udid.hasPrefix("2222"))
}

@Test func `an id resolves exactly, and anything ambiguous or unknown is refused`() throws {
    let inventory = try inventory()
    let id = "22222222-2222-2222-2222-222222222222"
    #expect(try inventory.resolve("platform=iOS Simulator,id=\(id.lowercased())").name == "iPhone 16")
    #expect(try inventory.resolve("platform=iOS Simulator,id=\(id)").destination == "platform=iOS Simulator,id=\(id)")
    for bad in [
        "platform=iOS Simulator,name=Twin", "platform=iOS Simulator,name=Nope",
        "platform=iOS Simulator,name=iPhone 15,OS=16", "platform=iOS Simulator,id=00000000-0000-0000-0000-000000000000",
        "platform=iOS Simulator", "platform=macOS", "platform=iOS Simulator,name=iPhone 15,name=iPhone 16",
    ] {
        #expect(throws: LitmusFailure.self, "\(bad)") { try inventory.resolve(bad) }
    }
}

@Test func `only a concrete iOS Simulator destination counts as a simulator`() {
    #expect(SimulatorInventory.isSimulatorDestination("platform=iOS Simulator,name=iPhone 16"))
    #expect(!SimulatorInventory.isSimulatorDestination("platform=macOS"))
    #expect(!SimulatorInventory.isSimulatorDestination("generic/platform=iOS"))
}

@Test func `a driver keeps every choice when its destination is replaced`() throws {
    var driver = try BuildDriver(
        root: "/repo",
        packagePath: "Pkg",
        scheme: "Lib",
        destination: "platform=iOS Simulator,name=iPhone 16"
    )
    driver.testPlan = "Plan"
    driver.xcodebuildArguments = ["-skipPackagePluginValidation"]
    let resolved = try driver.with(destination: "platform=iOS Simulator,id=ABC")
    #expect(resolved.destination == "platform=iOS Simulator,id=ABC")
    #expect(resolved.packagePath == "Pkg" && resolved.scheme == "Lib" && resolved.testPlan == "Plan")
    #expect(resolved.xcodebuildArguments == ["-skipPackagePluginValidation"])
}

@Test func `an unknown destination names the available simulators, newest runtime first`() throws {
    let simulators = try inventory()
    do {
        _ = try simulators.resolve("platform=iOS Simulator,id=DEADBEEF-0000-0000-0000-000000000000")
        Issue.record("an unknown id resolved")
    } catch let failure as LitmusFailure {
        let message = String(describing: failure)
        #expect(message.contains("available: iPhone 15 (iOS 18.10, id=55555555-5555-5555-5555-555555555555)"))
        #expect(!message.contains("iPad Air") && !message.contains("Watch"))
    }
    #expect(SimulatorInventory(devices: []).availableList.hasPrefix("none"))
}
