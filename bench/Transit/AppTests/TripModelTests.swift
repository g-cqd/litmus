import FareKit
import Testing
import TripKit

@testable import Transit

@MainActor
@Suite struct TripModelTests {
    @Test func `the fare follows the trip and the clock`() {
        let model = TripModel()
        #expect(model.isPeak)
        #expect(model.fare == Fare(cents: 450))
        model.minuteOfDay = 12 * 60
        #expect(model.fare == Fare(cents: 360))
    }

    @Test func `buying pays from the wallet`() {
        let model = TripModel()
        model.buy()
        #expect(model.wallet.balance == 550)
        #expect(model.lastMessage == "Paid €4.50")
    }

    @Test func `a poor wallet cannot buy`() {
        let model = TripModel()
        model.zones = 6
        model.buy()
        model.buy()
        #expect(!model.canAfford)
        #expect(model.lastMessage == "Top up to travel")
    }

    @Test func `the status line describes the journey`() {
        let model = TripModel()
        #expect(model.statusLine == "60 min, 1 change")
        model.journey = Journey(legs: [])
        #expect(model.statusLine == "No connection")
    }

    @Test func `amounts are shown in euros`() {
        #expect(TripModel.euros(450) == "€4.50")
        #expect(TripModel.euros(1_205) == "€12.05")
        #expect(TripModel.euros(-30) == "-€0.30")
    }
}
