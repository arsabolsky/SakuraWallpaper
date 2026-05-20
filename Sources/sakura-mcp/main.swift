import Cocoa
import SakuraWallpaperCore

// Minimal NSApplication bootstrap for ScreenPlayer windowing.
// No dock icon, no menu bar — runs as background agent.
NSApp.setActivationPolicy(.accessory)

let wallpaperManager = WallpaperManager()

// Restore previously configured wallpapers
wallpaperManager.restoreAllScreens()

// Start MCP stdio server on stdin/stdout
let server = MCPServer(wallpaperManager: wallpaperManager)
server.run()

// Keep run loop alive while MCP server processes messages
RunLoop.main.run()
