import Testing
import TripKit

@Suite struct JourneyTests {
    let direct = Journey(legs: [Leg(from: "A", to: "B", departs: 480, arrives: 500)])
    let connected = Journey(legs: [
        Leg(from: "A", to: "B", departs: 480, arrives: 500),
        Leg(from: "B", to: "C", departs: 505, arrives: 530),
    ])

    @Test func `a direct journey is feasible`() { #expect(direct.isFeasible) }

    @Test func `a journey needs legs`() { #expect(!Journey(legs: []).isFeasible) }

    @Test func `a connection needs the minimum change time and the same stop`() {
        #expect(connected.isFeasible)
        let tight = Journey(legs: [connected.legs[0], Leg(from: "B", to: "C", departs: 502, arrives: 530)])
        #expect(!tight.isFeasible)
        let elsewhere = Journey(legs: [connected.legs[0], Leg(from: "X", to: "C", departs: 505, arrives: 530)])
        #expect(!elsewhere.isFeasible)
    }

    @Test func `durations and changes`() {
        #expect(connected.totalMinutes == 50)
        #expect(connected.changes == 1)
        #expect(connected.waitingMinutes == 5)
        #expect(direct.changes == 0)
    }
}
