import AemiJSON
import AemiMCP
import Testing

@testable import LitmusCore

@Suite struct McpServerTests {
    static let server = McpServer.make(tools: [MCPTool(name: "echo", description: "Echoes text.")]) { name, arguments in
        guard name == "echo" else { throw LitmusFailure("unknown tool \(name)") }
        return try arguments.string("text") ?? ""
    }

    static func reply(_ line: String) async throws -> JSON? {
        guard let bytes = await server.handle(Array(line.utf8)) else { return nil }
        return try AemiJSON.parse(bytes).root
    }

    @Test func `initialize answers the client's protocol version with the tools capability`() async throws {
        let reply = try #require(
            try await Self.reply(
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#
            )
        )
        #expect(reply["result"]["protocolVersion"].string == "2025-03-26")
        #expect(reply["result"]["capabilities"]["tools"].isObject)
        #expect(reply["result"]["serverInfo"]["name"].string == "litmus")
        #expect(reply["id"].int == 1)
    }

    @Test func `notifications get no reply, and malformed or unknown requests get JSON-RPC errors`() async throws {
        #expect(try await Self.reply(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        let parse = try #require(try await Self.reply("{not json"))
        #expect(parse["error"]["code"].int == -32700)
        let unknown = try #require(try await Self.reply(#"{"jsonrpc":"2.0","id":"a","method":"nope"}"#))
        #expect(unknown["error"]["code"].int == -32601)
        #expect(unknown["id"].string == "a")
    }

    @Test func `tool calls return text content, and a failing tool is an error result, not a protocol error`()
        async throws
    {
        let listed = try #require(try await Self.reply(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        #expect(listed["result"]["tools"].count == 1)
        let call = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}"#
        let ok = try #require(try await Self.reply(call))["result"]
        #expect(ok["isError"].bool == false)
        #expect(ok["content"][index: 0]["text"].string == "hi")
        let bad = #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"other"}}"#
        #expect(try #require(try await Self.reply(bad))["result"]["isError"].bool == true)
    }

    @Test func `the four tools keep their names and required inputs`() {
        let tools = Dictionary(uniqueKeysWithValues: McpServer.tools.map { ($0.name, $0) })
        #expect(Set(tools.keys) == ["litmus_plan", "litmus_run", "litmus_gaps", "litmus_accept"])
        let required = { (name: String) -> [String] in
            let schema = (try? AemiJSON.parse(tools[name]?.inputSchema.bytes ?? []))?.root
            return schema?["required"].arrayValue.compactMap(\.string) ?? []
        }
        #expect(required("litmus_run") == ["root", "trust_project"])
        #expect(required("litmus_accept") == ["root", "run", "id", "reason"])
    }
}
