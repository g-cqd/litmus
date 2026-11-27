import Foundation
import Testing

@testable import LitmusCore

@Suite struct McpServerTests {
    static var tools: [[String: Any]] { [["name": "echo", "inputSchema": ["type": "object"]]] }

    static func reply(_ line: String) async -> [String: Any]? {
        await McpServer.handle(line, tools: tools) { name, arguments in
            guard name == "echo" else { throw LitmusFailure("unknown tool \(name)") }
            return arguments["text"] as? String ?? ""
        }
    }

    @Test func `initialize answers the client's protocol version with the tools capability`() async throws {
        let reply = try #require(
            await Self.reply(
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#
            )
        )
        let result = try #require(reply["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-03-26")
        #expect((result["capabilities"] as? [String: Any])?["tools"] != nil)
        #expect(reply["id"] as? Int == 1)
    }

    @Test func `notifications get no reply, and malformed or unknown requests get JSON-RPC errors`() async throws {
        #expect(await Self.reply(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        let parse = try #require(await Self.reply("{not json"))
        #expect((parse["error"] as? [String: Any])?["code"] as? Int == -32700)
        let unknown = try #require(await Self.reply(#"{"jsonrpc":"2.0","id":"a","method":"nope"}"#))
        #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32601)
        #expect(unknown["id"] as? String == "a")
    }

    @Test func `tool calls return text content, and a failing tool is an error result, not a protocol error`()
        async throws
    {
        let listed = try #require(await Self.reply(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        #expect(((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.count == 1)
        let call = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}"#
        let ok = try #require((await Self.reply(call))?["result"] as? [String: Any])
        #expect(ok["isError"] as? Bool == false)
        #expect((ok["content"] as? [[String: Any]])?.first?["text"] as? String == "hi")
        let bad = #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"other"}}"#
        let failed = try #require((await Self.reply(bad))?["result"] as? [String: Any])
        #expect(failed["isError"] as? Bool == true)
    }
}
