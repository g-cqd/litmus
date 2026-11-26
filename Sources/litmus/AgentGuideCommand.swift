import AnalyzerCLI
import ArgumentParser
import Foundation
import LitmusCore

struct AgentGuideCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent-guide",
        abstract: "Print, or install for coding agents, the workflow that closes mutation gaps with Litmus."
    )
    @Flag(help: "Write the guide into the repository instead of printing it.") var install = false
    @Option(help: "With --install: agents (.agents/skills), claude (.claude/skills) or agents-md (repeatable).")
    var target: [String] = ["agents"]
    @Option(help: "Repository root to install into.") var root: String = "."

    mutating func run() async throws {
        guard install else {
            print(Self.skill, terminator: "")
            return
        }
        var targets: [AgentGuide.Target] = []
        for name in target {
            guard let known = AgentGuide.Target(rawValue: name) else {
                throw ValidationError("target must be agents, claude or agents-md")
            }
            targets.append(known)
        }
        let root = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
        let guide = AgentGuide(tool: "litmus", skill: Self.skill, pointer: Self.pointer)
        do {
            for installation in try guide.install(root: root, targets: targets) {
                stderr("litmus: \(installation.changed ? "wrote" : "up to date:") \(installation.path)")
            }
        } catch { try fail(error, code: .outputFailure) }
    }

    static let pointer = """
        Mutation testing: Litmus checks that tests detect injected faults. Read `.agents/skills/litmus/SKILL.md` (or run \
        `litmus agent-guide`) before closing mutation gaps.
        """

    static let skill = """
        ---
        name: litmus
        description: "Close mutation-testing gaps with Litmus: find the mutants tests miss, strengthen the tests, re-verify one mutant in seconds, and accept only proven equivalences."
        ---

        # Closing mutation gaps with Litmus

        Litmus changes production code one small fault at a time (a mutant) and runs the tests. A mutant the tests do \
        not detect is a gap: either a missing or weak assertion, or an equivalent change that no test can detect.

        ## 1. Run a scoped baseline

        Run only what the change touches, in a persistent workspace (outside the repository) so later runs compile \
        incrementally:

        ```sh
        litmus run . --trust-project --diff-base origin/main --workspace persistent:../.litmus-workspace \
            --output "$(mktemp -d)/run"
        # or a path: --only-path Sources/Feature/; Xcode projects add --scheme and --destination
        ```

        ## 2. Read the gaps

        ```sh
        litmus analyze . --results <run>/run.json --format agent --domain logic
        ```

        Each gap carries the mutated code (`original` → `replacement`), a numbered `contextSnippet`, the tests that \
        reached it (`reachingTests`), the test targets covering its file, and a `verifyCommand`.

        - `not_reached`: no test runs this code. Write a test that calls `declaration` on the path that reaches the line.
        - `reached_not_detected`: tests ran the mutated code and still passed. Add the assertion they miss: the boundary \
        (`>` vs `>=`), the error or empty case, the exact value rather than "non-nil".

        ## 3. Write the test, then re-verify that one mutant

        Write behavioural assertions on observable results. Never mirror the implementation in the test, and never \
        assert on Litmus itself. Then run the gap's `verifyCommand` (it uses `--only-id <id>`; add the same `--workspace` \
        as the baseline): it rewrites only the mutated file and runs only the covering tests. The mutant must now be \
        `killed`.

        ## 4. Accept only proven equivalences

        When no test can tell the mutant from the original (for example `a > b ? a - b : 0` vs `>=`: both give 0 when \
        `a == b`), record the proof instead of a comment in the source:

        ```sh
        litmus accept <id> --from <run> --reason "a == b gives a - b == 0, the else value, so > and >= agree"
        ```

        The reason must state the invariant or algebra, not "ok". `litmus run --verify-accepted` later reports \
        acceptances a test now detects (`stale-killed`) and those whose code is gone (`stale-missing`); remove them with \
        `litmus unaccept <id>`.

        ## Rules

        - Never edit production code to make a mutant disappear; change the tests.
        - Never accept a mutant without a concrete proof of equivalence.
        - A run executes the project's code: pass `--trust-project` only on code you trust.

        """
}
