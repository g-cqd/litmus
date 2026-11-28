import AemiJSON
import AemiMCP
import LitmusCore

/// What `litmus mcp`'s tools do. Each runs this executable's own subcommand, so a tool call is exactly what the same
/// command line would do, and answers with compact JSON text.
enum McpTools {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private struct Plan: Encodable {
        let count: Int
        let mutants: [McpMutation]
    }

    private struct Run: Encodable {
        let run: String
        let exit: Int
        let score: Double?
        let results: [McpMutation]
    }

    @Sendable static func call(_ name: String, _ arguments: MCPToolArguments) async throws -> String {
        let root = try arguments.requiredString("root")
        switch name {
        case "litmus_plan":
            var command = ["plan", root]
            if let operators = try arguments.string("operators") { command += ["--operators", operators] }
            if let base = try arguments.string("diff_base") { command += ["--diff-base", base] }
            let output = try await checked(command, timeout: 600)
            let plan = try ArtifactCodec.decode(MutationPlan.self, bytes: output.stdout)
            return try json(
                Plan(count: plan.mutations.count, mutants: plan.mutations.prefix(200).map { McpMutation($0) })
            )
        case "litmus_run":
            return try await run(root: root, arguments)
        case "litmus_gaps":
            let run = try arguments.requiredString("run")
            let path = run.hasSuffix(".json") || run.hasSuffix(".pb") ? run : run + "/run.json"
            let domain = try arguments.string("domain") ?? "all"
            let output = try await LitmusChild.run(
                ["analyze", root, "--results", path, "--format", "agent", "--domain", domain],
                timeout: 600
            )
            guard !output.stdout.isEmpty else { throw Failure(description: tail(output.stderr)) }
            return String(decoding: output.stdout, as: UTF8.self)
        case "litmus_accept":
            let command = [
                "accept", try arguments.requiredString("id"), "--from", try arguments.requiredString("run"),
                "--reason", try arguments.requiredString("reason"), "--root", root,
            ]
            let output = try await checked(command, timeout: 120)
            return tail(output.stderr + output.stdout)
        default:
            throw Failure(description: "unknown tool \(name)")
        }
    }

    private static func run(root: String, _ arguments: MCPToolArguments) async throws -> String {
        guard try arguments.bool("trust_project") == true else {
            throw Failure(description: "trust_project must be true: a run builds and executes the subject's code")
        }
        let cache = try LitmusChild.cache("mcp", root: root)
        let directory = LitmusChild.runDirectory(in: cache)
        var command = LitmusChild.warmRunArguments(root: root, cache: cache, output: directory) + ["--trust-project"]
        for id in try arguments.strings("only_ids") { command += ["--only-id", id] }
        if let operators = try arguments.string("operators") { command += ["--operators", operators] }
        command += try arguments.strings("arguments")
        let timeout = try arguments.integer("timeout_seconds", in: 1...86_400) ?? 3600
        let output = try await LitmusChild.run(command, timeout: timeout)
        guard let artifact = try? ArtifactCodec.read(RunArtifact.self, path: directory + "/run.json") else {
            throw Failure(description: "no run artifact (exit \(output.exitStatus)): " + tail(output.stderr))
        }
        let results = artifact.results.prefix(200).map {
            McpMutation($0.mutation, verdict: $0.verdict.rawValue, reason: $0.reason)
        }
        return try json(
            Run(run: directory, exit: Int(output.exitStatus), score: artifact.score.percent, results: results)
        )
    }

    static func checked(_ command: [String], timeout: Int) async throws -> ProcessOutput {
        let output = try await LitmusChild.run(command, timeout: timeout)
        guard output.exitStatus == 0, !output.timedOut else {
            throw Failure(description: "litmus \(command[0]) exited \(output.exitStatus): " + tail(output.stderr))
        }
        return output
    }

    private static func json(_ value: some Encodable) throws -> String {
        String(decoding: try AemiJSON.JSONEncoder().encodeToBytes(value), as: UTF8.self)
    }

    static func tail(_ bytes: [UInt8]) -> String {
        String(String(decoding: bytes, as: UTF8.self).suffix(2000))
    }
}
