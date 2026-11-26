import Foundation
import Testing

@testable import LitmusCore

@Suite("Phase D: shared execution, inner loop, diff intelligence & operations")
struct PhaseDTests {
    // MARK: - D5.1 Tokenized schema environment

    @Test func `the environment token is eight stable hex digits that differ per subject root`() {
        let first = ActivationEnvironment.token(for: "/tmp/subject-a")
        #expect(first.count == 8)
        #expect(first.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(first == ActivationEnvironment.token(for: "/tmp/subject-a"))
        #expect(first != ActivationEnvironment.token(for: "/tmp/subject-b"))
    }

    @Test func `a tokenized schema reads only its own run's variables`() throws {
        let source = "func f(a: Bool) -> Int { a ? 1 : 2 }"
        let sites = try MutationPlanner.mutations(in: source, path: "F.swift")
        let schema = try SchemaWriter.schema(source, mutations: sites, token: "0a1b2c3d")
        for base in [
            ActivationEnvironment.activeID, ActivationEnvironment.coverageDirectory,
            ActivationEnvironment.testTracePath,
        ] {
            #expect(schema.text.contains("\"\(base)_0a1b2c3d\""))
            #expect(!schema.text.contains("\"\(base)\""))
        }
        // Without a token, the bare names stay: a schema written by an older run reads what it always read.
        let bare = try SchemaWriter.schema(source, mutations: sites)
        #expect(bare.text.contains("\"\(ActivationEnvironment.activeID)\""))
    }

    @Test func `the subject environment carries the request's tokenized keys and no bare ones`() {
        var request = TestRunRequest(
            name: "t",
            activeID: "0123456789abcdef",
            coverageDirectory: "/tmp/c",
            temporaryDirectory: "/tmp/t",
            deadline: 10,
            failFast: false
        )
        request.environmentToken = "deadbeef"
        let environment = subjectEnvironment(request)
        #expect(environment["LITMUS_ACTIVE_ID_deadbeef"] == "0123456789abcdef")
        #expect(environment["LITMUS_COVERAGE_DIR_deadbeef"] == "/tmp/c")
        #expect(environment["LITMUS_ACTIVE_ID"] == nil)
        #expect(environment["LITMUS_COVERAGE_DIR"] == nil)
        #expect(
            ActivationEnvironment.key(ActivationEnvironment.testTracePath, token: "deadbeef")
                == "LITMUS_TEST_TRACE_deadbeef"
        )
    }
}
