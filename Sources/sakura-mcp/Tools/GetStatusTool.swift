import Cocoa
import SakuraWallpaperCore

enum GetStatusTool {
    static func register(in registry: ToolRegistry, wallpaperManager: WallpaperManager?) {
        registry.register(MCPToolDefinition(
            name: "get_status",
            description: "Get current wallpaper playback status for all screens or a specific one.",
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
            guard let wm = wallpaperManager else {
                throw MCPToolError(message: "Wallpaper engine unavailable — run from GUI session")
            }
            let targetID = args["screen_id"]?.stringValue
            let screens = NSScreen.screens

            var result: [[String: JSONRPCValue]] = []
            for screen in screens {
                let id = SettingsManager.screenIdentifier(screen)
                if let t = targetID, t != id { continue }

                let config = SettingsManager.shared.screenConfig(for: id)
                let isPlaying = wm.currentFiles[id] != nil
                let currentPath = wm.currentFiles[id]?.path

                var entry: [String: JSONRPCValue] = [
                    "id": .string(id),
                    "name": .string(screen.localizedName),
                    "is_playing": .bool(isPlaying),
                    "is_paused": .bool(wm.isPaused),
                    "is_folder_mode": .bool(config.isFolderMode),
                    "rotation_interval_minutes": .number(Double(config.rotationIntervalMinutes)),
                    "shuffle": .bool(config.isShuffleMode),
                    "include_subfolders": .bool(config.includeSubfolders),
                    "fit_mode": .string(config.wallpaperFit.rawValue)
                ]
                if let p = currentPath { entry["current_file"] = .string(p) }
                if let fp = config.folderPath { entry["folder_path"] = .string(fp) }
                if let wp = config.wallpaperPath { entry["wallpaper_path"] = .string(wp) }
                result.append(entry)
            }

            return .object(["screens": .array(result.map { .object($0) })])
        }
    }
}
