internal import Foundation

/// The Model Context Protocol's JSON-RPC 2.0 dispatch for `litmus mcp`: lifecycle, tool listing and tool calls,
/// with the tools supplied by the caller.
public enum McpServer {
    public static let protocolVersion = "2025-06-18"

    /// The reply to one JSON-RPC message, or nil for a notification.
    public static func handle(
        _ line: String,
        tools: [[String: Any]],
        call: (String, [String: Any]) async throws -> String
    ) async -> [String: Any]? {
        guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            return error(id: NSNull(), code: -32700, "parse error")
        }
        let id = message["id"]
        guard let method = message["method"] as? String else {
            return id == nil ? nil : error(id: id, code: -32600, "invalid request")
        }
        guard let id else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            return result(
                id: id,
                [
                    "protocolVersion": params["protocolVersion"] as? String ?? protocolVersion,
                    "capabilities": ["tools": [String: Any]()],
                    "serverInfo": ["name": "litmus", "version": LitmusVersion.current],
                ]
            )
        case "ping": return result(id: id, [:])
        case "tools/list": return result(id: id, ["tools": tools])
        case "tools/call":
            guard let name = params["name"] as? String else { return error(id: id, code: -32602, "missing tool name") }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                let text = try await call(name, arguments)
                return result(id: id, ["content": [["type": "text", "text": text]], "isError": false])
            } catch {
                return result(id: id, ["content": [["type": "text", "text": "\(error)"]], "isError": true])
            }
        default: return McpServer.error(id: id, code: -32601, "method not found: \(method)")
        }
    }

    static func result(id: Any, _ value: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": value]
    }

    static func error(id: Any?, code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    public static func write(_ reply: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }
}
