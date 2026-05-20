import Foundation
import SakuraWallpaperCore

struct MCPToolDefinition {
    let name: String
    let description: String
    let inputSchema: [String: JSONRPCValue]

    var json: JSONRPCValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "inputSchema": .object(inputSchema)
        ])
    }
}

final class ToolRegistry {
    private var handlers: [String: ([String: JSONRPCValue]) throws -> JSONRPCValue] = [:]

    var toolDefinitions: [MCPToolDefinition] = []

    func register(_ definition: MCPToolDefinition, handler: @escaping ([String: JSONRPCValue]) throws -> JSONRPCValue) {
        toolDefinitions.append(definition)
        handlers[definition.name] = handler
    }

    func invoke(name: String, arguments: [String: JSONRPCValue]) throws -> JSONRPCValue {
        guard let handler = handlers[name] else {
            throw MCPToolError(message: "Unknown tool: \(name)")
        }
        return try handler(arguments)
    }

    func registerAll(wallpaperManager: WallpaperManager) {
        ListScreensTool.register(in: self)
        GetStatusTool.register(in: self, wallpaperManager: wallpaperManager)
        SetWallpaperTool.register(in: self, wallpaperManager: wallpaperManager)
        SetFolderTool.register(in: self, wallpaperManager: wallpaperManager)
        StopWallpaperTool.register(in: self, wallpaperManager: wallpaperManager)
        PauseResumeTool.register(in: self, wallpaperManager: wallpaperManager)
        NextWallpaperTool.register(in: self, wallpaperManager: wallpaperManager)
        GetSettingsTool.register(in: self)
        UpdateSettingsTool.register(in: self, wallpaperManager: wallpaperManager)
    }
}
