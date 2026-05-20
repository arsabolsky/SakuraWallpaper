import SakuraWallpaperCore

// Start MCP stdio server — works in both GUI (Claude Desktop) and CLI contexts.
// WallpaperManager is nil when no window server; tools report "unavailable".
let server = MCPServer(wallpaperManager: nil)

// Observe state changes from the GUI app
IPCSync.observeStateChanges { _ in }

server.run()
