import Cocoa
import SakuraWallpaperCore

enum SetWallpaperTool {
    static func register(in registry: ToolRegistry, wallpaperManager: WallpaperManager) {
        registry.register(MCPToolDefinition(
            name: "set_wallpaper",
            description: "Set a single image or video file as wallpaper on one or all screens.",
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "file_path": .object([
                        "type": .string("string"),
                        "description": .string("Absolute path to the image or video file.")
                    ]),
                    "screen_id": .object([
                        "type": .string("string"),
                        "description": .string("Screen ID from list_screens. Omit for all screens.")
                    ])
                ]),
                "required": .array([.string("file_path")])
            ]
        )) { args in
            guard let filePath = args["file_path"]?.stringValue, !filePath.isEmpty else {
                throw MCPToolError(message: "file_path is required and must be non-empty")
            }

            let url = URL(fileURLWithPath: filePath)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: filePath, isDirectory: &isDir) else {
                throw MCPToolError(message: "File not found: \(filePath)")
            }
            guard !isDir.boolValue else {
                throw MCPToolError(message: "Path is a directory, not a file. Use set_folder for folders.")
            }

            let mediaType = MediaType.detect(url)
            guard mediaType != .unsupported else {
                throw MCPToolError(message: "Unsupported file format. Supported: mp4, mov, gif, m4v, png, jpg, jpeg, heic, webp, bmp, tiff")
            }

            let targetID = args["screen_id"]?.stringValue
            let screens = NSScreen.screens

            if let t = targetID {
                guard let screen = screens.first(where: { SettingsManager.screenIdentifier($0) == t }) else {
                    throw MCPToolError(message: "Screen not found: \(t)")
                }
                wallpaperManager.setWallpaper(url: url, for: screen)
            } else {
                for screen in screens {
                    wallpaperManager.setWallpaper(url: url, for: screen)
                }
            }

            return .object([
                "success": .bool(true),
                "file_path": .string(filePath)
            ])
        }
    }
}
