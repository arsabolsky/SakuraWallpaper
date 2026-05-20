import Foundation
import SakuraWallpaperCore

final class MCPServer {
    private let wallpaperManager: WallpaperManager?
    private let registry = ToolRegistry()
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    init(wallpaperManager: WallpaperManager?) {
        self.wallpaperManager = wallpaperManager
        registry.registerAll(wallpaperManager: wallpaperManager)
    }

    func run() {
        setbuf(stdin, nil)
        setbuf(stdout, nil)

        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let message = try? decoder.decode(JSONRPCMessage.self, from: data) else {
                continue
            }
            handle(message)
        }
    }

    private func handle(_ message: JSONRPCMessage) {
        switch message {
        case .request(let id, let method, let params):
            switch method {
            case "initialize":
                send(.response(id: id, result: .object([
                    "protocolVersion": .string("2024-11-05"),
                    "capabilities": .object(["tools": .object([:])]),
                    "serverInfo": .object([
                        "name": .string("sakura-mcp"),
                        "version": .string("1.0.0")
                    ])
                ])))
            case "tools/list":
                send(.response(id: id, result: .object([
                    "tools": .array(registry.toolDefinitions.map { $0.json })
                ])))
            case "tools/call":
                guard let toolName = params?["name"]?.stringValue,
                      let arguments = params?["arguments"]?.objectValue else {
                    send(.error(id: id, code: -32602, message: "Invalid params"))
                    return
                }
                do {
                    let result = try registry.invoke(name: toolName, arguments: arguments)
                    send(.response(id: id, result: result))
                } catch let error as MCPToolError {
                    send(.error(id: id, code: -32000, message: error.message))
                } catch {
                    send(.error(id: id, code: -32603, message: error.localizedDescription))
                }
            default:
                send(.error(id: id, code: -32601, message: "Method not found: \(method)"))
            }
        case .notification(let method, _):
            if method == "notifications/initialized" {
                // Session ready — no response needed per MCP spec
            }
        case .response, .error:
            break // Server never receives these
        }
    }

    private func send(_ message: JSONRPCMessage) {
        guard let data = try? encoder.encode(message),
              let json = String(data: data, encoding: .utf8) else { return }
        print(json)
        fflush(stdout)
    }
}

// MARK: - JSON-RPC Value

indirect enum JSONRPCValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONRPCValue])
    case array([JSONRPCValue])
    case null

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var numberValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var objectValue: [String: JSONRPCValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) { self = .string(s) }
        else if let n = try? container.decode(Double.self) { self = .number(n) }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let o = try? container.decode([String: JSONRPCValue].self) { self = .object(o) }
        else if let a = try? container.decode([JSONRPCValue].self) { self = .array(a) }
        else if container.decodeNil() { self = .null }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown JSONRPC value") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        case .bool(let b): try container.encode(b)
        case .object(let o): try container.encode(o)
        case .array(let a): try container.encode(a)
        case .null: try container.encodeNil()
        }
    }
}

// MARK: - JSON-RPC Message

enum JSONRPCMessage: Codable {
    case request(id: String, method: String, params: [String: JSONRPCValue]?)
    case response(id: String, result: JSONRPCValue)
    case error(id: String?, code: Int, message: String)
    case notification(method: String, params: [String: JSONRPCValue]?)

    enum CodingKeys: String, CodingKey { case jsonrpc, id, method, params, result, error }
    enum ErrorKeys: String, CodingKey { case code, message }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let method = try container.decodeIfPresent(String.self, forKey: .method)
        let id = try container.decodeIfPresent(String.self, forKey: .id)

        if let method = method {
            if let id = id {
                let params = try container.decodeIfPresent([String: JSONRPCValue].self, forKey: .params)
                self = .request(id: id, method: method, params: params)
            } else {
                let params = try container.decodeIfPresent([String: JSONRPCValue].self, forKey: .params)
                self = .notification(method: method, params: params)
            }
        } else if let id = id {
            if container.contains(.error) {
                let errContainer = try container.nestedContainer(keyedBy: ErrorKeys.self, forKey: .error)
                let code = try errContainer.decode(Int.self, forKey: .code)
                let message = try errContainer.decode(String.self, forKey: .message)
                self = .error(id: id, code: code, message: message)
            } else {
                let result = try container.decode(JSONRPCValue.self, forKey: .result)
                self = .response(id: id, result: result)
            }
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: container.codingPath, debugDescription: "Invalid JSON-RPC message"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("2.0", forKey: .jsonrpc)
        switch self {
        case .request(let id, let method, let params):
            try container.encode(id, forKey: .id)
            try container.encode(method, forKey: .method)
            try container.encodeIfPresent(params, forKey: .params)
        case .response(let id, let result):
            try container.encode(id, forKey: .id)
            try container.encode(result, forKey: .result)
        case .error(let id, let code, let message):
            try container.encodeIfPresent(id, forKey: .id)
            var errContainer = container.nestedContainer(keyedBy: ErrorKeys.self, forKey: .error)
            try errContainer.encode(code, forKey: .code)
            try errContainer.encode(message, forKey: .message)
        case .notification(let method, let params):
            try container.encode(method, forKey: .method)
            try container.encodeIfPresent(params, forKey: .params)
        }
    }
}

// MARK: - MCP Tool Error

struct MCPToolError: Error {
    let message: String
}
