import Foundation

public enum MCPControlValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: MCPControlValue])
    case array([MCPControlValue])
    case null

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode([String: MCPControlValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([MCPControlValue].self) {
            self = .array(value)
        } else if container.decodeNil() {
            self = .null
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown MCP control value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public struct MCPControlRequest: Codable, Equatable {
    public let toolName: String
    public let arguments: [String: MCPControlValue]

    public init(toolName: String, arguments: [String: MCPControlValue]) {
        self.toolName = toolName
        self.arguments = arguments
    }
}

public struct MCPControlResponse: Codable, Equatable {
    public let result: MCPControlValue?
    public let errorMessage: String?

    public init(result: MCPControlValue) {
        self.result = result
        self.errorMessage = nil
    }

    public init(errorMessage: String) {
        self.result = nil
        self.errorMessage = errorMessage
    }
}

public enum MCPControlChannel {
    public static let messagePortName = "com.sakura.wallpaper.mcp.gui-control"
}
