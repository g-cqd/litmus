import FareKit
import SwiftUI
import TripKit
import WalletKit

@main
struct TransitApp: App {
    var body: some Scene {
        WindowGroup { TripView(model: TripModel()) }
    }
}

/// What the trip screen shows: the fare, whether the wallet covers it, and the journey's status.
@MainActor
@Observable
final class TripModel {
    var rider: Rider = .adult
    var age = 30
    var zones = 2
    var minuteOfDay = 8 * 60
    var weekday = true
    var wallet = Wallet(balance: 1_000)
    var journey = Journey(legs: [
        Leg(from: "Central", to: "Harbour", departs: 480, arrives: 500),
        Leg(from: "Harbour", to: "Airport", departs: 506, arrives: 540),
    ])
    var lastMessage = ""

    var isPeak: Bool { TransferPolicy.isPeak(minuteOfDay: minuteOfDay, weekday: weekday) }

    var fare: Fare { Tariff().fare(zones: zones, rider: rider, age: age, peak: isPeak) }

    var canAfford: Bool { wallet.balance >= fare.cents }

    var statusLine: String {
        guard journey.isFeasible else { return "No connection" }
        let changes = journey.changes == 1 ? "1 change" : "\(journey.changes) changes"
        return "\(journey.totalMinutes) min, \(changes)"
    }

    func buy() {
        do {
            try wallet.pay(fare.cents)
            lastMessage = "Paid \(Self.euros(fare.cents))"
        } catch {
            lastMessage = "Top up to travel"
        }
    }

    static func euros(_ cents: Int) -> String {
        let sign = cents < 0 ? "-" : ""
        let value = abs(cents)
        let rest = value % 100
        return "\(sign)€\(value / 100).\(rest < 10 ? "0" : "")\(rest)"
    }
}

struct TripView: View {
    @State var model: TripModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Trip") {
                    Stepper("Zones: \(model.zones)", value: $model.zones, in: 1...6)
                    Picker("Rider", selection: $model.rider) {
                        ForEach(Rider.allCases, id: \.self) { Text($0.rawValue.capitalized) }
                    }
                    Text(model.statusLine).accessibilityIdentifier("status")
                    if model.isPeak {
                        Label("Peak hours", systemImage: "clock.badge.exclamationmark")
                    }
                }
                Section("Fare") {
                    Text(TripModel.euros(model.fare.cents)).font(.title2).accessibilityIdentifier("fare")
                    Button("Buy ticket") { model.buy() }
                        .disabled(!model.canAfford)
                        .accessibilityIdentifier("buy")
                    Text(model.lastMessage).foregroundStyle(.secondary).accessibilityIdentifier("message")
                }
            }
            .navigationTitle("Transit")
        }
    }
}
