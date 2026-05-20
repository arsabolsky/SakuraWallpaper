import SakuraWallpaperCore

enum PauseResumeTool {
    static func register(in registry: ToolRegistry, wallpaperManager: WallpaperManager?) {
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
            guard let wm = wallpaperManager else {
                throw MCPToolError(message: "Wallpaper engine unavailable — run from GUI session")
            }
            guard let action = args["action"]?.stringValue else {
                throw MCPToolError(message: "action is required: 'pause', 'resume', or 'toggle'")
            }

            switch action {
            case "pause":
                wm.isPaused = true
                wm.checkPlaybackState()
            case "resume":
                wm.isPaused = false
                wm.checkPlaybackState()
            case "toggle":
                wm.isPaused.toggle()
                wm.checkPlaybackState()
            default:
                throw MCPToolError(message: "Invalid action: '\(action)'. Use 'pause', 'resume', or 'toggle'.")
            }

            IPCSync.notifyStateChanged(field: "paused")

            return .object([
                "paused": .bool(wm.isPaused)
            ])
        }
    }
}
