import Cocoa
import SakuraWallpaperCore

enum ListScreensTool {
    static func register(in registry: ToolRegistry) {
        registry.register(MCPToolDefinition(
            name: "list_screens",
            description: "List all connected displays with their identifiers, names, and resolutions.",
            inputSchema: [
                "type": .string("object"),
                "properties": .object([:]),
                "required": .array([])
            ]
        )) { _ in
            let screens = NSScreen.screens.map { screen -> [String: JSONRPCValue] in
                let id = SettingsManager.screenIdentifier(screen)
                let frame = screen.frame
                return [
                    "id": .string(id),
                    "name": .string(screen.localizedName),
                    "x": .number(frame.origin.x),
                    "y": .number(frame.origin.y),
                    "width": .number(frame.size.width),
                    "height": .number(frame.size.height)
                ]
            }
            return .object(["screens": .array(screens.map { .object($0) })])
        }
    }
}
