import Cocoa
import SakuraWallpaperCore

enum UpdateSettingsTool {
    static func register(in registry: ToolRegistry, wallpaperManager: WallpaperManager) {
        registry.register(MCPToolDefinition(
            name: "update_settings",
            description: "Update wallpaper configuration parameters without changing the current wallpaper.",
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "screen_id": .object([
                        "type": .string("string"),
                        "description": .string("Screen ID. Omit for all screens.")
                    ]),
                    "rotation_interval_minutes": .object([
                        "type": .string("number"),
                        "description": .string("Minutes between wallpaper changes.")
                    ]),
                    "shuffle": .object([
                        "type": .string("boolean"),
                        "description": .string("Enable or disable shuffle.")
                    ]),
                    "rotation_enabled": .object([
                        "type": .string("boolean"),
                        "description": .string("Enable or disable wallpaper rotation.")
                    ]),
                    "include_subfolders": .object([
                        "type": .string("boolean"),
                        "description": .string("Include files from subdirectories.")
                    ]),
                    "fit_mode": .object([
                        "type": .string("string"),
                        "description": .string("fill, fit, or stretch.")
                    ]),
                    "is_synced": .object([
                        "type": .string("boolean"),
                        "description": .string("Sync settings across screens.")
                    ])
                ]),
                "required": .array([])
            ]
        )) { args in
            let targetID = args["screen_id"]?.stringValue
            let screens = NSScreen.screens
            var updatedFields: [String] = []

            func apply(to id: String) {
                var config = SettingsManager.shared.screenConfig(for: id)

                if let v = args["rotation_interval_minutes"]?.numberValue {
                    config.rotationIntervalMinutes = max(1, Int(v))
                    updatedFields.append("rotation_interval_minutes")
                }
                if let v = args["shuffle"]?.boolValue {
                    config.isShuffleMode = v
                    updatedFields.append("shuffle")
                }
                if let v = args["rotation_enabled"]?.boolValue {
                    config.isRotationEnabled = v
                    updatedFields.append("rotation_enabled")
                }
                if let v = args["include_subfolders"]?.boolValue {
                    config.includeSubfolders = v
                    updatedFields.append("include_subfolders")
                    if let fp = config.folderPath,
                       let screen = screens.first(where: { SettingsManager.screenIdentifier($0) == id }) {
                        wallpaperManager.setFolder(url: URL(fileURLWithPath: fp), for: screen, config: config)
                        return
                    }
                }
                if let v = args["fit_mode"]?.stringValue, let fit = WallpaperFitMode(rawValue: v) {
                    config.wallpaperFit = fit
                    updatedFields.append("fit_mode")
                }
                if let v = args["is_synced"]?.boolValue {
                    config.isSynced = v
                    updatedFields.append("is_synced")
                }

                SettingsManager.shared.setScreenConfig(config, for: id)
            }

            if let t = targetID {
                guard screens.contains(where: { SettingsManager.screenIdentifier($0) == t }) else {
                    throw MCPToolError(message: "Screen not found: \(t)")
                }
                apply(to: t)
            } else {
                for screen in screens {
                    apply(to: SettingsManager.screenIdentifier(screen))
                }
            }

            return .object([
                "success": .bool(true),
                "updated_fields": .array(updatedFields.map { .string($0) })
            ])
        }
    }
}
