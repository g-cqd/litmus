import AemiRuntime
import Foundation
import Synchronization
import Testing

@testable import LitmusCore

/// Per-test reach in the judge (t37, t38): a mutant runs only the tests that reach it, a failure counts as a kill when
/// a failing test reaches it, and a failure by tests that do not reach it is never its kill.
@Suite struct ReachTests {
    /// Answers each run from a script and marks the active mutant as reached.
    final class ScriptedHarness: TestHarness {
        var maximumWorkers: Int { 1 }
        var kind: String { "scripted" }
        var selectsTests: Bool { true }
        var selectsModules: Bool { true }
        var controlsSwiftTesting: Bool { true }
        let requests = Mutex<[TestRunRequest]>([])
        let respond: @Sendable (TestRunRequest) -> TestRunResult

        init(_ respond: @escaping @Sendable (TestRunRequest) -> TestRunResult) { self.respond = respond }

        func run(_ request: TestRunRequest) async throws -> TestRunResult {
            requests.withLock { $0.append(request) }
            if !request.activeID.isEmpty {
                FileManager.default.createFile(
                    atPath: request.coverageDirectory + "/" + request.activeID,
                    contents: nil
                )
            }
            return respond(request)
        }
    }

    static func result(_ outcome: TestRunOutcome, passed: Int = 0, failing: [String] = []) -> TestRunResult {
        var result = TestRunResult(
            outcome: outcome,
            counts: outcome == .passed ? TestCounts(passed: passed, failed: 0, skipped: 0) : nil,
            nanoseconds: 1,
            evidence: [],
            reason: outcome.rawValue
        )
        result.failingTests = failing
        return result
    }

    let site = Mutation(
        id: "00000000000000aa",
        path: "A.swift",
        line: 1,
        column: 1,
        operatorID: .negateCondition,
        start: 0,
        end: 1,
        original: "a",
        replacement: "!(a)",
        sourceFingerprint: "f"
    )

    func judge(_ harness: ScriptedHarness, confirmation: KillConfirmation = .targeted) throws -> Judge {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("litmus-reach-" + UUID().uuidString)
        var options = RunOptions()
        options.killConfirmation = confirmation
        let pool = try ResourcePool(count: 1) { index in try WorkerSlot(root: root.path, index: index) }
        var judge = Judge(
            harness: harness,
            pool: pool,
            options: options,
            counter: RunCounter(),
            baseline: TestCounts(passed: 10, failed: 0, skipped: 0),
            deadline: 5,
            parallelDeadline: 5,
            rerunDeadline: 10
        )
        judge.reach = [site.id: ["M.reaches()", "M.also()"]]
        judge.testCounts = [
            "M.reaches()": TestCounts(passed: 1, failed: 0, skipped: 0),
            "M.also()": TestCounts(passed: 2, failed: 0, skipped: 0),
        ]
        return judge
    }

    @Test func `a mutant runs only its reaching tests, and passes on their counts`() async throws {
        let harness = ScriptedHarness { _ in Self.result(.passed, passed: 3) }
        let judge = try judge(harness)
        #expect(judge.selected(site) == ["M.also()", "M.reaches()"])
        #expect(judge.expected(site) == TestCounts(passed: 3, failed: 0, skipped: 0))
        guard case .done(let decision) = try await judge.first(site) else {
            Issue.record("expected a decision"); return
        }
        #expect(decision.verdict == .survived)
        #expect(harness.requests.withLock { $0.map(\.onlySwiftTesting) } == [["M.also()", "M.reaches()"]])
    }

    @Test func `a failing reaching test is a kill without confirmation reruns`() async throws {
        let harness = ScriptedHarness { _ in Self.result(.failed, failing: ["M.reaches()"]) }
        let judge = try judge(harness)
        guard case .rerun(let pending) = try await judge.first(site) else { Issue.record("expected a rerun"); return }
        let decision = try await judge.finish(pending)
        #expect(decision.verdict == .killed)
        #expect(decision.reason.contains("per-test reach"))
        #expect(harness.requests.withLock { $0.count } == 1)
    }

    @Test func `failing tests that do not reach the mutant are not its kill`() async throws {
        // The first run fails in a test that does not reach the mutant (a timing test under load); alone, the
        // reaching tests pass: the mutant survived.
        let calls = Atomic<Int>(0)
        let harness = ScriptedHarness { _ in
            calls.add(1, ordering: .relaxed).oldValue == 0
                ? Self.result(.failed, failing: ["M.timing()"]) : Self.result(.passed, passed: 3)
        }
        for confirmation in [KillConfirmation.targeted, .none] {
            calls.store(0, ordering: .relaxed)
            let judge = try judge(harness, confirmation: confirmation)
            guard case .rerun(let pending) = try await judge.first(site) else {
                Issue.record("expected a rerun"); return
            }
            let decision = try await judge.finish(pending)
            #expect(decision.verdict == .survived, "\(confirmation)")
        }
    }

    @Test func `without reach, or with an unknown count, nothing is selected`() throws {
        var judge = try judge(ScriptedHarness { _ in Self.result(.passed, passed: 10) })
        judge.testCounts["M.also()"] = nil
        #expect(judge.selected(site) == nil)
        #expect(judge.expected(site) == TestCounts(passed: 10, failed: 0, skipped: 0))
        judge.reach = [:]
        #expect(!judge.reachRejects(site, failing: ["M.timing()"]))
    }
}
