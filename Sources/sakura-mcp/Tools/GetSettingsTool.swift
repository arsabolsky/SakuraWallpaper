import Cocoa
import SakuraWallpaperCore

enum GetSettingsTool {
    static func register(in registry: ToolRegistry) {
        registry.register(MCPToolDefinition(
            name: "get_settings",
            description: "Read current wallpaper configuration for one or all screens.",
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

            var result: [[String: JSONRPCValue]] = []
            for screen in screens {
                let id = SettingsManager.screenIdentifier(screen)
                if let t = targetID, t != id { continue }

                let config = SettingsManager.shared.screenConfig(for: id)
                var entry: [String: JSONRPCValue] = [
                    "id": .string(id),
                    "name": .string(screen.localizedName),
                    "rotation_interval_minutes": .number(Double(config.rotationIntervalMinutes)),
                    "shuffle": .bool(config.isShuffleMode),
                    "rotation_enabled": .bool(config.isRotationEnabled),
                    "include_subfolders": .bool(config.includeSubfolders),
                    "is_folder_mode": .bool(config.isFolderMode),
                    "is_synced": .bool(config.isSynced),
                    "fit_mode": .string(config.wallpaperFit.rawValue)
                ]
                if let fp = config.folderPath { entry["folder_path"] = .string(fp) }
                if let wp = config.wallpaperPath { entry["wallpaper_path"] = .string(wp) }
                result.append(entry)
            }

            return .object(["screens": .array(result.map { .object($0) })])
        }
    }
}
