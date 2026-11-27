import Foundation
import Testing

@testable import LitmusCore

@Test func `the static deadline holds until a run kind has enough samples`() {
    let timings = MutantTimings()
    for _ in 0..<(MutantTimings.minimumSamples - 1) { timings.record(1_000_000_000, kind: "tests") }
    #expect(timings.deadline(kind: "tests", cap: 156, factor: 4, minimum: 3, alone: false) == 156)
    timings.record(1_000_000_000, kind: "tests")
    // 4 × 1 s + 2 s.
    #expect(timings.deadline(kind: "tests", cap: 156, factor: 4, minimum: 3, alone: false) == 6)
    #expect(timings.deadline(kind: "tests", cap: 156, factor: 4, minimum: 3, alone: true) == 12)
    // Another kind is still on the static deadline.
    #expect(timings.deadline(kind: "modules:A", cap: 156, factor: 4, minimum: 3, alone: false) == 156)
}

@Test func `the observed deadline follows the 95th percentile within the minimum and the cap`() {
    let timings = MutantTimings()
    // 19 runs of 0.5 s and one of 10 s: the 95th percentile of 20 is the 19th, 0.5 s.
    for _ in 0..<19 { timings.record(500_000_000, kind: "tests") }
    timings.record(10_000_000_000, kind: "tests")
    #expect(timings.percentile95(kind: "tests") == 500_000_000)
    #expect(timings.deadline(kind: "tests", cap: 300, factor: 4, minimum: 3, alone: false) == 4)
    #expect(timings.deadline(kind: "tests", cap: 300, factor: 4, minimum: 10, alone: false) == 10)
    #expect(timings.deadline(kind: "tests", cap: 3, factor: 4, minimum: 1, alone: true) == 3)
    // A slower tail lifts it: with two slow runs of 21, the 95th percentile is a slow one.
    timings.record(10_000_000_000, kind: "tests")
    #expect(timings.percentile95(kind: "tests") == 10_000_000_000)
    #expect(timings.deadline(kind: "tests", cap: 300, factor: 4, minimum: 3, alone: false) == 42)
}

@Test func `run kinds separate narrowed runs from module sets`() {
    #expect(MutantTimings.kind(tests: ["A.a()"], modules: ["A"]) == "tests")
    #expect(MutantTimings.kind(tests: nil, modules: ["B", "A"]) == "modules:A,B")
    #expect(MutantTimings.kind(tests: nil, modules: nil) == "modules:*")
    let timings = MutantTimings()
    timings.record(0, kind: "tests")
    #expect(timings.percentile95(kind: "tests") == nil)
    for _ in 0..<8 { timings.record(2_000_000_000, kind: "modules:A,B") }
    let summary = timings.summary(factor: 4, minimum: 3, cap: 156)
    #expect(summary == ["deadlines from observed times: runs of A,B, 95th percentile 2.0 s over 8 runs, deadline 10 s"])
}
