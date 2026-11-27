import Foundation
import LitmusCore

/// The tools `litmus mcp` offers. Each runs this executable's own subcommand, so a tool call is exactly what the same
/// command line would do, and answers with compact JSON text.
enum McpTools {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static var definitions: [[String: Any]] {
        [
            tool(
                "litmus_plan",
                "List the mutants Litmus would run in a subject (ids, locations, operators, diffs), without building.",
                [
                    "root": string("Subject root."),
                    "operators": string("Comma-separated operators or groups (all, ui, fault)."),
                    "diff_base": string("Only sites changed since this git revision."),
                ],
                required: ["root"]
            ),
            tool(
                "litmus_run",
                "Run mutants and return their verdicts. Builds incrementally in a persistent directory per subject and reuses verdicts whose inputs did not change.",
                [
                    "root": string("Subject root."),
                    "trust_project": [
                        "type": "boolean",
                        "description": "Required true: the run builds and executes the subject's code.",
                    ],
                    "only_ids": [
                        "type": "array", "items": ["type": "string"],
                        "description": "Run only these mutants (ids, prefixes or path:line[:operator]).",
                    ],
                    "operators": string("Comma-separated operators or groups (all, ui, fault)."),
                    "arguments": [
                        "type": "array", "items": ["type": "string"],
                        "description": "More `litmus run` arguments, such as --project, --scheme, --destination.",
                    ],
                    "timeout_seconds": [
                        "type": "integer", "description": "Stop the run after this long (default 3600).",
                    ],
                ],
                required: ["root", "trust_project"]
            ),
            tool(
                "litmus_gaps",
                "Every survivor and uncovered mutant of a run, each a self-contained record with its code, diff and a verify command.",
                [
                    "root": string("Subject root."), "run": string("Run directory or run.json."),
                    "domain": string("logic, ui or all (default all)."),
                ],
                required: ["root", "run"]
            ),
            tool(
                "litmus_accept",
                "Accept a reviewed equivalent mutant in .litmus-accepted.json, with the proof of equivalence as its reason.",
                [
                    "root": string("Subject root."),
                    "run": string("Run directory or run.json the mutant was reported in."),
                    "id": string("Mutant id, id prefix, or path:line:operator."),
                    "reason": string("Why it is equivalent."),
                ],
                required: ["root", "run", "id", "reason"]
            ),
        ]
    }

    static func call(_ name: String, _ arguments: [String: Any]) async throws -> String {
        func text(_ key: String) throws -> String {
            guard let value = arguments[key] as? String, !value.isEmpty else {
                throw Failure(description: "\(key) is required")
            }
            return value
        }
        let root = try text("root")
        switch name {
        case "litmus_plan":
            var command = ["plan", root]
            if let operators = arguments["operators"] as? String { command += ["--operators", operators] }
            if let base = arguments["diff_base"] as? String { command += ["--diff-base", base] }
            let output = try await checked(command, timeout: 600)
            let plan = try ArtifactCodec.decode(MutationPlan.self, bytes: output.stdout)
            return try json(["count": plan.mutations.count, "mutants": plan.mutations.prefix(200).map(summary)])
        case "litmus_run":
            guard arguments["trust_project"] as? Bool == true else {
                throw Failure(description: "trust_project must be true: a run builds and executes the subject's code")
            }
            let cache = try LitmusChild.cache("mcp", root: root)
            let directory = LitmusChild.runDirectory(in: cache)
            var command =
                LitmusChild.warmRunArguments(root: root, cache: cache, output: directory) + ["--trust-project"]
            for id in arguments["only_ids"] as? [String] ?? [] { command += ["--only-id", id] }
            if let operators = arguments["operators"] as? String { command += ["--operators", operators] }
            command += arguments["arguments"] as? [String] ?? []
            let output = try await LitmusChild.run(command, timeout: arguments["timeout_seconds"] as? Int ?? 3600)
            guard let artifact = try? ArtifactCodec.read(RunArtifact.self, path: directory + "/run.json") else {
                throw Failure(description: "no run artifact (exit \(output.exitStatus)): " + tail(output.stderr))
            }
            return try json([
                "run": directory, "exit": Int(output.exitStatus), "score": artifact.score.percent as Any,
                "results": artifact.results.prefix(200).map { result in
                    summary(result.mutation).merging(["verdict": result.verdict.rawValue, "reason": result.reason]) {
                        a,
                        _ in a
                    }
                },
            ])
        case "litmus_gaps":
            let run = try text("run")
            let path = run.hasSuffix(".json") || run.hasSuffix(".pb") ? run : run + "/run.json"
            let domain = arguments["domain"] as? String ?? "all"
            let output = try await LitmusChild.run(
                ["analyze", root, "--results", path, "--format", "agent", "--domain", domain],
                timeout: 600
            )
            guard !output.stdout.isEmpty else { throw Failure(description: tail(output.stderr)) }
            return String(decoding: output.stdout, as: UTF8.self)
        case "litmus_accept":
            let command = [
                "accept", try text("id"), "--from", try text("run"), "--reason", try text("reason"), "--root", root,
            ]
            let output = try await checked(command, timeout: 120)
            return tail(output.stderr + output.stdout)
        default: throw Failure(description: "unknown tool \(name)")
        }
    }

    static func checked(_ command: [String], timeout: Int) async throws -> ProcessOutput {
        let output = try await LitmusChild.run(command, timeout: timeout)
        guard output.exitStatus == 0, !output.timedOut else {
            throw Failure(description: "litmus \(command[0]) exited \(output.exitStatus): " + tail(output.stderr))
        }
        return output
    }

    static func summary(_ mutation: Mutation) -> [String: Any] {
        [
            "id": mutation.id, "path": mutation.path, "line": mutation.line, "operator": mutation.operatorID.rawValue,
            "original": mutation.original, "replacement": mutation.replacement,
        ]
    }

    static func json(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }

    static func tail(_ bytes: [UInt8]) -> String {
        String(String(decoding: bytes, as: UTF8.self).suffix(2000))
    }

    static func string(_ description: String) -> [String: Any] { ["type": "string", "description": description] }

    static func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String])
        -> [String: Any]
    {
        [
            "name": name, "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required],
        ]
    }
}
