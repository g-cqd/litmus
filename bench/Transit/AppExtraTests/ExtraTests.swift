import FareKit
import Testing

@testable import Transit

/// A unit-test target the Transit scheme leaves out: only `--all-test-targets` (or a tool that finds every target)
/// runs it.
@MainActor
@Suite struct ExtraTests {
    @Test func `students pay less off peak`() {
        let model = TripModel()
        model.rider = .student
        model.minuteOfDay = 13 * 60
        #expect(model.fare == Fare(cents: 250))
    }

    @Test func `two changes are pluralised`() {
        let model = TripModel()
        model.journey = .init(
            legs: model.journey.legs + [.init(from: "Airport", to: "Terminal", departs: 545, arrives: 550)]
        )
        #expect(model.statusLine == "70 min, 2 changes")
    }
}
