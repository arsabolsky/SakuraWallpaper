import SakuraWallpaperCore

enum PauseResumeTool {
    static func register(in registry: ToolRegistry, wallpaperManager: WallpaperManager) {
        registry.register(MCPToolDefinition(
            name: "pause_resume",
            description: "Pause or resume wallpaper playback. When paused, videos freeze and rotation stops.",
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "action": .object([
                        "type": .string("string"),
                        "description": .string("'pause', 'resume', or 'toggle'.")
                    ])
                ]),
                "required": .array([.string("action")])
            ]
        )) { args in
            guard let action = args["action"]?.stringValue else {
                throw MCPToolError(message: "action is required: 'pause', 'resume', or 'toggle'")
            }

            switch action {
            case "pause":
                wallpaperManager.isPaused = true
                wallpaperManager.checkPlaybackState()
            case "resume":
                wallpaperManager.isPaused = false
                wallpaperManager.checkPlaybackState()
            case "toggle":
                wallpaperManager.isPaused.toggle()
                wallpaperManager.checkPlaybackState()
            default:
                throw MCPToolError(message: "Invalid action: '\(action)'. Use 'pause', 'resume', or 'toggle'.")
            }

            return .object([
                "paused": .bool(wallpaperManager.isPaused)
            ])
        }
    }
}
