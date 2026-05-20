import Cocoa
import SakuraWallpaperCore

enum StopWallpaperTool {
    static func register(in registry: ToolRegistry, wallpaperManager: WallpaperManager?) {
        registry.register(MCPToolDefinition(
            name: "stop_wallpaper",
            description: "Stop wallpaper playback on one or all screens.",
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "screen_id": .object([
                        "type": .string("string"),
                        "description": .string("Screen ID from list_screens. Omit to stop all.")
                    ])
                ]),
                "required": .array([])
            ]
        )) { args in
            guard let wm = wallpaperManager else {
                throw MCPToolError(message: "Wallpaper engine unavailable — run from GUI session")
            }
            let targetID = args["screen_id"]?.stringValue
            let screens = NSScreen.screens

            var stopped: [String] = []
            if let t = targetID {
                guard let screen = screens.first(where: { SettingsManager.screenIdentifier($0) == t }) else {
                    throw MCPToolError(message: "Screen not found: \(t)")
                }
                wm.stopWallpaper(for: screen)
                stopped = [t]
            } else {
                wm.stopAll()
                stopped = screens.map { SettingsManager.screenIdentifier($0) }
            }

            IPCSync.notifyStateChanged(screenID: targetID, field: "stopped")

            return .object([
                "success": .bool(true),
                "stopped_screens": .array(stopped.map { .string($0) })
            ])
        }
    }
}
