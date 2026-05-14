import XCTest
@testable import SakuraWallpaperCore

final class WallpaperBehaviorPolicyTests: XCTestCase {
    func testDisablingDesktopSyncRequestsRestoreWhenOriginalDesktopExists() {
        let action = WallpaperBehavior.desktopSyncAction(
            wasEnabled: true,
            isEnabled: false,
            hasOriginalDesktopRecord: true
        )

        XCTAssertEqual(action, .restoreOriginalDesktop)
    }

    func testDisablingDesktopSyncDoesNotRestoreWhenNoOriginalDesktopExists() {
        let action = WallpaperBehavior.desktopSyncAction(
            wasEnabled: true,
            isEnabled: false,
            hasOriginalDesktopRecord: false
        )

        XCTAssertEqual(action, .none)
    }

    func testBatterySaverPausesWhenDesktopIsCoveredEvenWithHealthyBattery() {
        let shouldPause = WallpaperBehavior.shouldAutoPausePlayback(
            pauseWhenInvisibleEnabled: true,
            batteryLevel: 88,
            isCharging: true,
            isDesktopCovered: true
        )

        XCTAssertTrue(shouldPause)
    }

    func testBatterySaverPausesOnLowBatteryWhenDesktopRemainsVisible() {
        let shouldPause = WallpaperBehavior.shouldAutoPausePlayback(
            pauseWhenInvisibleEnabled: true,
            batteryLevel: 20,
            isCharging: false,
            isDesktopCovered: false
        )

        XCTAssertTrue(shouldPause)
    }

    func testBatterySaverDoesNotPauseWhenDisabled() {
        let shouldPause = WallpaperBehavior.shouldAutoPausePlayback(
            pauseWhenInvisibleEnabled: false,
            batteryLevel: 5,
            isCharging: false,
            isDesktopCovered: true
        )

        XCTAssertFalse(shouldPause)
    }
}
