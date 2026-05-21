import Foundation
import SakuraWallpaperCore

final class MCPGUIForwarder {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let forwardedTools: Set<String> = [
        "get_status",
        "set_wallpaper",
        "set_folder",
        "stop_wallpaper",
        "pause_resume",
        "next_wallpaper",
        "get_settings",
        "update_settings"
    ]

    static func guiEndpointAvailable() -> Bool {
        CFMessagePortCreateRemote(nil, MCPControlChannel.messagePortName as CFString) != nil
    }

    func canForward(toolName: String) -> Bool {
        forwardedTools.contains(toolName)
    }

    func call(toolName: String, arguments: [String: JSONRPCValue]) throws -> JSONRPCValue {
        guard let remote = CFMessagePortCreateRemote(nil, MCPControlChannel.messagePortName as CFString) else {
            throw MCPToolError(message: "SakuraWallpaper app is no longer available")
        }

        let request = MCPControlRequest(
            toolName: toolName,
            arguments: arguments.mapValues { $0.controlValue }
        )
        let payload = try encoder.encode(request)
        var responseData: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(
            remote,
            0,
            payload as CFData,
            3,
            3,
            CFRunLoopMode.defaultMode.rawValue,
            &responseData
        )
        guard status == kCFMessagePortSuccess,
              let responseData = responseData?.takeRetainedValue() as Data? else {
            throw MCPToolError(message: "Failed to forward request to SakuraWallpaper app")
        }

        let response = try decoder.decode(MCPControlResponse.self, from: responseData)
        if let errorMessage = response.errorMessage {
            throw MCPToolError(message: errorMessage)
        }
        guard let result = response.result else {
            throw MCPToolError(message: "SakuraWallpaper app returned an empty response")
        }
        return JSONRPCValue(controlValue: result)
    }
}

extension JSONRPCValue {
    var controlValue: MCPControlValue {
        switch self {
        case .string(let value): return .string(value)
        case .number(let value): return .number(value)
        case .bool(let value): return .bool(value)
        case .object(let value): return .object(value.mapValues { $0.controlValue })
        case .array(let value): return .array(value.map { $0.controlValue })
        case .null: return .null
        }
    }

    init(controlValue: MCPControlValue) {
        switch controlValue {
        case .string(let value): self = .string(value)
        case .number(let value): self = .number(value)
        case .bool(let value): self = .bool(value)
        case .object(let value): self = .object(value.mapValues { JSONRPCValue(controlValue: $0) })
        case .array(let value): self = .array(value.map { JSONRPCValue(controlValue: $0) })
        case .null: self = .null
        }
    }
}
