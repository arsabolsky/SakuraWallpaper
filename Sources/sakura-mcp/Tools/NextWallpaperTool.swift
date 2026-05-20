import Cocoa
import SakuraWallpaperCore

enum NextWallpaperTool {
    static func register(in registry: ToolRegistry, wallpaperManager: WallpaperManager) {
        registry.register(MCPToolDefinition(
            name: "next_wallpaper",
            description: "Skip to the next wallpaper in the rotation for one or all screens.",
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "screen_id": .object([
                        "type": .string("string"),
                        "description": .string("Screen ID from list_screens. Omit for all screens.")
                    ])
                ]),
                "required": .array([])
            ]
        )) { args in
            let targetID = args["screen_id"]?.stringValue
            let screens = NSScreen.screens

            var results: [[String: JSONRPCValue]] = []
            if let t = targetID {
                guard let screen = screens.first(where: { SettingsManager.screenIdentifier($0) == t }) else {
                    throw MCPToolError(message: "Screen not found: \(t)")
                }
                wallpaperManager.nextWallpaper(for: screen)
                let newFile = wallpaperManager.currentFiles[t]?.path ?? ""
                results.append(["id": .string(t), "new_file": .string(newFile)])
            } else {
                wallpaperManager.nextWallpaper()
                for screen in screens {
                    let id = SettingsManager.screenIdentifier(screen)
                    let newFile = wallpaperManager.currentFiles[id]?.path ?? ""
                    results.append(["id": .string(id), "new_file": .string(newFile)])
                }
            }

            return .object([
                "success": .bool(true),
                "results": .array(results.map { .object($0) })
            ])
        }
    }
}
