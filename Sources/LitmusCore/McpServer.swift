internal import AemiJSONCore
public import AemiMCP

/// `litmus mcp`'s Model Context Protocol server: its tools, and AemiMCP's dispatch (protocol negotiation, cancellation,
/// strict JSON-RPC). What a tool does is the caller's `call`.
public enum McpServer {
    /// What a tool call runs: the tool's name and its validated arguments, answered with JSON text.
    public typealias Call = @Sendable (String, MCPToolArguments) async throws -> String

    /// The server for `tools`, each call answered by `call` as one text block; a call that throws is an error result.
    public static func make(tools: [MCPTool] = McpServer.tools, call: @escaping Call) -> MCPServer {
        MCPServer(
            configuration: MCPServerConfiguration(name: "litmus", version: LitmusVersion.current),
            tools: tools,
            callTool: { name, arguments in .text(try await call(name, arguments)) }
        )
    }

    /// The tools `litmus mcp` offers. Each runs the matching subcommand of the same executable.
    public static let tools: [MCPTool] = [
        tool(
            "litmus_plan",
            "List the mutants Litmus would run in a subject (ids, locations, operators, diffs), without building.",
            [
                "root": MCPSchema.string("Subject root."),
                "operators": MCPSchema.string("Comma-separated operators or groups (all, ui, fault)."),
                "diff_base": MCPSchema.string("Only sites changed since this git revision."),
            ],
            required: ["root"]
        ),
        tool(
            "litmus_run",
            "Run mutants and return their verdicts. Builds incrementally in a persistent directory per subject and "
                + "reuses verdicts whose inputs did not change.",
            [
                "root": MCPSchema.string("Subject root."),
                "trust_project": MCPSchema.boolean("Required true: the run builds and executes the subject's code."),
                "only_ids": MCPSchema.array(
                    items: MCPSchema.string(),
                    "Run only these mutants (ids, prefixes or path:line[:operator])."
                ),
                "operators": MCPSchema.string("Comma-separated operators or groups (all, ui, fault)."),
                "arguments": MCPSchema.array(
                    items: MCPSchema.string(),
                    "More `litmus run` arguments, such as --project, --scheme, --destination."
                ),
                "timeout_seconds": MCPSchema.integer("Stop the run after this long (default 3600)."),
            ],
            required: ["root", "trust_project"]
        ),
        tool(
            "litmus_gaps",
            "Every survivor and uncovered mutant of a run, each a self-contained record with its code, diff and a "
                + "verify command.",
            [
                "root": MCPSchema.string("Subject root."), "run": MCPSchema.string("Run directory or run.json."),
                "domain": MCPSchema.string("logic, ui or all (default all)."),
            ],
            required: ["root", "run"]
        ),
        tool(
            "litmus_accept",
            "Accept a reviewed equivalent mutant in .litmus-accepted.json, with the proof of equivalence as its reason.",
            [
                "root": MCPSchema.string("Subject root."),
                "run": MCPSchema.string("Run directory or run.json the mutant was reported in."),
                "id": MCPSchema.string("Mutant id, id prefix, or path:line:operator."),
                "reason": MCPSchema.string("Why it is equivalent."),
            ],
            required: ["root", "run", "id", "reason"]
        ),
    ]

    private static func tool(
        _ name: String,
        _ description: String,
        _ properties: KeyValuePairs<String, JSONValue>,
        required: [String]
    ) -> MCPTool {
        MCPTool(
            name: name,
            description: description,
            schema: MCPSchema.object(properties: properties, required: required)
        )
    }
}

/// A mutation as a tool reports it.
public struct McpMutation: Encodable, Sendable {
    public let id: String
    public let path: String
    public let line: Int
    public let `operator`: String
    public let original: String
    public let replacement: String
    /// A run's verdict and its reason; nil in a plan.
    public let verdict: String?
    public let reason: String?

    public init(_ mutation: Mutation, verdict: String? = nil, reason: String? = nil) {
        id = mutation.id
        path = mutation.path
        line = mutation.line
        self.operator = mutation.operatorID.rawValue
        original = mutation.original
        replacement = mutation.replacement
        self.verdict = verdict
        self.reason = reason
    }
}
