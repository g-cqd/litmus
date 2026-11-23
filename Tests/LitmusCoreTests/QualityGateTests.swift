import Foundation
import Testing

@testable import LitmusCore

private func run(
    killed: Int,
    survived: Int,
    unresolved: Int = 0,
    files: Set<String> = ["A.swift"],
    operators: Set<String> = ["negate-condition"],
    scoped: Bool = false
) -> QualityGate.Measured {
    var verdicts = Array(repeating: Verdict.killed, count: killed) + Array(repeating: .survived, count: survived)
    verdicts += Array(repeating: .notRun, count: unresolved)
    var measured = QualityGate.Measured(score: MutationScore(verdicts), operators: operators, files: files)
    measured.scoped = scoped
    return measured
}

@Test func `a score under the minimum fails and one at it passes`() {
    let gate = QualityGate(minimumScore: 80)
    #expect(gate.failures(for: run(killed: 8, survived: 2), baseline: nil).isEmpty)
    let low = gate.failures(for: run(killed: 7, survived: 3), baseline: nil)
    #expect(low.count == 1 && low[0].contains("70 %") && low[0].contains("minimum 80 %"))
}

@Test func `a run with unresolved mutants has no score to judge`() {
    let failures = QualityGate(minimumScore: 50).failures(
        for: run(killed: 9, survived: 0, unresolved: 1),
        baseline: nil
    )
    #expect(failures.count == 1 && failures[0].contains("no resolved verdict"))
}

@Test func `a run that decided nothing passes a minimum, and an empty gate passes everything`() {
    #expect(QualityGate(minimumScore: 90).failures(for: run(killed: 0, survived: 0), baseline: nil).isEmpty)
    #expect(QualityGate().failures(for: run(killed: 1, survived: 9), baseline: nil).isEmpty)
}

@Test func `a score drop beyond the limit fails, within it passes, and a rise passes`() {
    let before = run(killed: 9, survived: 1)
    let gate = QualityGate(maximumScoreDrop: 5)
    #expect(gate.failures(for: run(killed: 9, survived: 1), baseline: before).isEmpty)
    #expect(gate.failures(for: run(killed: 10, survived: 0), baseline: before).isEmpty)
    let fell = gate.failures(for: run(killed: 8, survived: 2), baseline: before)
    #expect(fell.count == 1 && fell[0].contains("fell 10 points") && fell[0].contains("90 % to 80 %"))
    #expect(QualityGate(maximumScoreDrop: 10).failures(for: run(killed: 8, survived: 2), baseline: before).isEmpty)
}

@Test func `scores that did not measure the same thing are not compared`() {
    let whole = run(killed: 9, survived: 1)
    let gate = QualityGate(maximumScoreDrop: 5)
    let others = [
        run(killed: 5, survived: 5, scoped: true),
        run(killed: 5, survived: 5, operators: ["flip-boolean"]),
        run(killed: 5, survived: 5, files: ["A.swift", "B.swift"]),
    ]
    for other in others {
        let failures = gate.failures(for: other, baseline: whole)
        #expect(failures.count == 1 && failures[0].contains("cannot be compared"), "\(failures)")
    }
    #expect(gate.failures(for: whole, baseline: nil)[0].contains("--baseline-run"))
}

@Test func `operators absent from an older artifact mean the stable tier`() {
    let stable = Set(MutationOperator.defaults.map(\.rawValue))
    let older = run(killed: 9, survived: 1, operators: stable)
    #expect(QualityGate.incomparable(older, run(killed: 1, survived: 0, operators: stable)) == nil)
}
