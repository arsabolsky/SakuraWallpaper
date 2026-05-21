import XCTest
@testable import sakura_mcp

final class MCPCoordinationTests: XCTestCase {
    func testRunModeUsesGUIForwardingWhenGUIEndpointExists() {
        let mode = MCPRunMode.resolve(hasGUI: true, guiEndpointAvailable: true, acquiredStandaloneLock: true)

        XCTAssertEqual(mode, .forwardToGUI)
    }

    func testRunModeUsesStandaloneWhenGUIEndpointIsMissingAndLockIsAcquired() {
        let mode = MCPRunMode.resolve(hasGUI: true, guiEndpointAvailable: false, acquiredStandaloneLock: true)

        XCTAssertEqual(mode, .standalone)
    }

    func testRunModeRejectsSecondStandaloneMCPWhenLockIsUnavailable() {
        let mode = MCPRunMode.resolve(hasGUI: true, guiEndpointAvailable: false, acquiredStandaloneLock: false)

        XCTAssertEqual(mode, .rejectDuplicate)
    }

    func testRunModeRejectsWithoutGUI() {
        let mode = MCPRunMode.resolve(hasGUI: false, guiEndpointAvailable: false, acquiredStandaloneLock: true)

        XCTAssertEqual(mode, .noGUI)
    }

    func testControlRequestRoundTrip() throws {
        let request = MCPControlRequest(toolName: "set_wallpaper", arguments: [
            "file_path": .string("/tmp/test.jpg")
        ])

        let encoded = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(MCPControlRequest.self, from: encoded)

        XCTAssertEqual(decoded.toolName, "set_wallpaper")
        XCTAssertEqual(decoded.arguments["file_path"], .string("/tmp/test.jpg"))
    }
}
