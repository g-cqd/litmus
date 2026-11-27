import TripKit
import XCTest

/// XCTest on purpose: a tool that runs only Swift Testing misses these kills.
final class DelayTests: XCTestCase {
    let journey = Journey(legs: [
        Leg(from: "A", to: "B", departs: 480, arrives: 500),
        Leg(from: "B", to: "C", departs: 510, arrives: 530),
        Leg(from: "C", to: "D", departs: 534, arrives: 550),
    ])

    func testSlackAbsorbsASmallDelay() {
        XCTAssertEqual(DelayPropagation.reachableLegs(in: journey, delayedLeg: 0, by: 7), 3)
    }

    func testALargeDelayBreaksTheConnection() {
        XCTAssertEqual(DelayPropagation.reachableLegs(in: journey, delayedLeg: 0, by: 8), 1)
        XCTAssertEqual(DelayPropagation.reachableLegs(in: journey, delayedLeg: 1, by: 2), 2)
    }

    func testAnUnknownLegReachesNothing() {
        XCTAssertEqual(DelayPropagation.reachableLegs(in: journey, delayedLeg: 5, by: 1), 0)
    }

    func testRecovery() {
        XCTAssertEqual(DelayPropagation.stopsToRecover(delay: 7, perStop: 2), 4)
        XCTAssertEqual(DelayPropagation.stopsToRecover(delay: 0, perStop: 2), 0)
    }

    func testLabels() {
        XCTAssertEqual(DelayPropagation.label(for: 0), "on time")
        XCTAssertEqual(DelayPropagation.label(for: 4), "minor delay")
        XCTAssertEqual(DelayPropagation.label(for: 5), "major delay")
    }
}
