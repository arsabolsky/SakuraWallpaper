import Cocoa
import SakuraWallpaperCore

// Detect GUI session: NSScreen.screens returns empty when no window server (SSH/CI).
// When launched from terminal within a GUI session or from Claude Desktop, it works.
// Use NSApplication.shared instead of NSApp — the latter crashes in SPM-built binaries.
let hasGUI = !NSScreen.screens.isEmpty

var wallpaperManager: WallpaperManager?
var forwarder: MCPGUIForwarder?
var singleInstanceLock: MCPSingleInstanceLock?
let guiEndpointAvailable = MCPGUIForwarder.guiEndpointAvailable()
let acquiredStandaloneLock: Bool
if hasGUI && !guiEndpointAvailable {
    let lock = MCPSingleInstanceLock()
    acquiredStandaloneLock = lock.acquire()
    singleInstanceLock = lock
} else {
    acquiredStandaloneLock = false
}
let runMode = MCPRunMode.resolve(
    hasGUI: hasGUI,
    guiEndpointAvailable: guiEndpointAvailable,
    acquiredStandaloneLock: acquiredStandaloneLock
)

switch runMode {
case .forwardToGUI:
    forwarder = MCPGUIForwarder()
case .standalone:
    NSApplication.shared.setActivationPolicy(.accessory)
    wallpaperManager = WallpaperManager()
    // Don't restore old state — MCP server is stateless.
    // User explicitly sets wallpapers via tools.
case .rejectDuplicate:
    fputs("Another standalone sakura-mcp is already running. Start SakuraWallpaper.app to share control, or stop the existing MCP process.\n", stderr)
case .noGUI:
    break
}

let unavailableMessage: String?
switch runMode {
case .rejectDuplicate:
    unavailableMessage = "Another standalone sakura-mcp is already running. Start SakuraWallpaper.app to share control, or stop the existing MCP process."
case .noGUI:
    unavailableMessage = "Wallpaper engine unavailable — run from GUI session"
case .forwardToGUI, .standalone:
    unavailableMessage = nil
}

let server = MCPServer(
    wallpaperManager: wallpaperManager,
    forwarder: forwarder,
    keepAliveAfterStdinCloses: runMode == .standalone,
    unavailableMessage: unavailableMessage
)

IPCSync.observeStateChanges { _ in }

// server.run() blocks until stdin closes, then enters RunLoop to keep
// ScreenPlayer windows alive (wallpaper persists after commands finish).
server.run()
