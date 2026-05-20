import Cocoa
import SakuraWallpaperCore

enum SetFolderTool {
    static func register(in registry: ToolRegistry, wallpaperManager: WallpaperManager) {
        registry.register(MCPToolDefinition(
            name: "set_folder",
            description: "Set a folder for wallpaper rotation on one or all screens.",
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "folder_path": .object([
                        "type": .string("string"),
                        "description": .string("Absolute path to a folder containing images/videos.")
                    ]),
                    "screen_id": .object([
                        "type": .string("string"),
                        "description": .string("Screen ID from list_screens. Omit for all screens.")
                    ]),
                    "rotation_interval_minutes": .object([
                        "type": .string("number"),
                        "description": .string("Minutes between wallpaper changes (default: 15).")
                    ]),
                    "shuffle": .object([
                        "type": .string("boolean"),
                        "description": .string("Randomize playback order.")
                    ]),
                    "include_subfolders": .object([
                        "type": .string("boolean"),
                        "description": .string("Include files from subdirectories.")
                    ]),
                    "fit_mode": .object([
                        "type": .string("string"),
                        "description": .string("Wallpaper fit mode: fill, fit, or stretch.")
                    ])
                ]),
                "required": .array([.string("folder_path")])
            ]
        )) { args in
            guard let folderPath = args["folder_path"]?.stringValue, !folderPath.isEmpty else {
                throw MCPToolError(message: "folder_path is required")
            }

            let folderURL = URL(fileURLWithPath: folderPath)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folderPath, isDirectory: &isDir), isDir.boolValue else {
                throw MCPToolError(message: "Folder not found or not a directory: \(folderPath)")
            }

            let targetID = args["screen_id"]?.stringValue
            let screens = NSScreen.screens
            let interval = args["rotation_interval_minutes"]?.numberValue.map { max(1, Int($0)) } ?? 15
            let shuffle = args["shuffle"]?.boolValue ?? false
            let includeSub = args["include_subfolders"]?.boolValue ?? false
            let fitRaw = args["fit_mode"]?.stringValue
            let fitMode: WallpaperFitMode = fitRaw.flatMap(WallpaperFitMode.init) ?? .fill
            let synced = screens.count > 1

            let config = Screen_Config(
                folderPath: folderPath,
                wallpaperPath: nil,
                rotationIntervalMinutes: interval,
                isShuffleMode: shuffle,
                isRotationEnabled: true,
                includeSubfolders: includeSub,
                isFolderMode: true,
                isSynced: synced,
                wallpaperFit: fitMode
            )

            if let t = targetID {
                guard let screen = screens.first(where: { SettingsManager.screenIdentifier($0) == t }) else {
                    throw MCPToolError(message: "Screen not found: \(t)")
                }
                wallpaperManager.setFolder(url: folderURL, for: screen, config: config)
            } else {
                for screen in screens {
                    wallpaperManager.setFolder(url: folderURL, for: screen, config: config)
                }
            }

            let fileCount = (try? PlaylistBuilder.collectMediaFiles(in: folderURL, includeSubfolders: includeSub).count) ?? 0

            return .object([
                "success": .bool(true),
                "folder_path": .string(folderPath),
                "file_count": .number(Double(fileCount))
            ])
        }
    }
}
