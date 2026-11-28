import AemiMCP
import ArgumentParser
import LitmusCore

/// `litmus mcp`: a Model Context Protocol server on stdin/stdout (newline-delimited JSON-RPC 2.0) whose tools plan,
/// run, report gaps and accept mutants for a coding agent. Requests are served one at a time, in order.
struct Mcp: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Serve Litmus's plan, run, gaps and accept tools to coding agents over MCP (stdio)."
    )

    mutating func run() async throws {
        await MCPStdioServer.serve(McpServer.make(call: McpTools.call), maxConcurrentRequests: 1)
    }
}
