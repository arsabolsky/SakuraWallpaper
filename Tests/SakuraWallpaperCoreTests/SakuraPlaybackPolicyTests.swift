// SakuraPlaybackPolicyTests.swift — determinism tests for SakuraPlaybackPolicy.compute.
// Phase 9: new tests for the playback policy tier computation.
//
// These tests run against the SakuraWallpaperCore package (which includes
// SakuraPlaybackPolicy via CORE_SRCS in build.sh and the Package.swift sources list).
// They verify tier boundaries so a future refactor can't silently change behaviour.

import XCTest
@testable import SakuraWallpaperCore

final class SakuraPlaybackPolicyTests: XCTestCase {

    // Convenient defaults — only override what a specific test needs.
    private func compute(
        presentationMode: String = "active",
        activityState: String = "active",
        userPaused: Bool = false,
        alwaysPauseDesktop: Bool = false,
        pauseWhenOccluded: Bool = false,
        desktopOccluded: Bool = false,
        thermalState: ProcessInfo.ThermalState = .nominal,
        isOnBattery: Bool = false,
        batteryLevel: Int = 100,
        isGameModeActive: Bool = false,
        displayBrightness: Float = 1.0
    ) -> SakuraPlaybackPolicy {
        SakuraPlaybackPolicy.compute(
            presentationMode: presentationMode,
            activityState: activityState,
            userPaused: userPaused,
            alwaysPauseDesktop: alwaysPauseDesktop,
            pauseWhenOccluded: pauseWhenOccluded,
            desktopOccluded: desktopOccluded,
            thermalState: thermalState,
            isOnBattery: isOnBattery,
            batteryLevel: batteryLevel,
            isGameModeActive: isGameModeActive,
            displayBrightness: displayBrightness
        )
    }

    // MARK: - Full tier

    func testIdealConditionsIsFull() {
        XCTAssertEqual(compute(), .full)
    }

    // MARK: - Paused tier

    func testUserPausedForcespaused() {
        XCTAssertEqual(compute(userPaused: true), .paused)
    }

    func testCriticalThermalForcespaused() {
        XCTAssertEqual(compute(thermalState: .critical), .paused)
    }

    func testBatteryBelow10ForcespaUsed() {
        XCTAssertEqual(compute(isOnBattery: true, batteryLevel: 9), .paused)
    }

    func testSuspendedActivityStateForcespaused() {
        XCTAssertEqual(compute(activityState: "suspended"), .paused)
    }

    func testIdlePresentationModeForcesPaused() {
        XCTAssertEqual(compute(presentationMode: "idle"), .paused)
    }

    func testGameModeForcespausedRegardlessOfBattery() {
        XCTAssertEqual(compute(isGameModeActive: true), .paused)
    }

    func testNearZeroBrightnessForcespauseds() {
        // Brightness below 0.05 triggers deep pause.
        XCTAssertEqual(compute(displayBrightness: 0.04), .paused)
    }

    func testBrightnessAtThresholdIsNotpaused() {
        // Exactly at threshold (0.05) is not considered "near zero".
        XCTAssertNotEqual(compute(displayBrightness: 0.05), .paused)
    }

    func testAlwaysPauseDesktopOnDesktopForcesPaused() {
        XCTAssertEqual(compute(alwaysPauseDesktop: true, presentationMode: "active"), .paused)
    }

    func testAlwaysPauseDesktopDoesNotpausedOnLockScreen() {
        // On the lock screen the wallpaper IS visible, so alwaysPauseDesktop must not fire.
        XCTAssertNotEqual(compute(alwaysPauseDesktop: true, presentationMode: "locked"), .paused)
    }

    func testOcclusionPausesOnlyWhenEnabled() {
        // Paused when occluded option is on and desktop is actually occluded.
        XCTAssertEqual(compute(pauseWhenOccluded: true, desktopOccluded: true), .paused)
        // Occluded but option off — should not be paused.
        XCTAssertNotEqual(compute(pauseWhenOccluded: false, desktopOccluded: true), .paused)
    }

    func testOcclusionSkippedOnLockScreen() {
        // On the lock screen the wallpaper is shown even if the desktop is "occluded".
        XCTAssertNotEqual(
            compute(pauseWhenOccluded: true, desktopOccluded: true, presentationMode: "locked"),
            .paused
        )
    }

    // MARK: - Minimal tier

    func testSeriousThermalIsMinimal() {
        XCTAssertEqual(compute(thermalState: .serious), .minimal)
    }

    func testBatteryBelow20OnBatteryIsMinimal() {
        XCTAssertEqual(compute(isOnBattery: true, batteryLevel: 19), .minimal)
    }

    // MARK: - Reduced tier

    func testFairThermalIsReduced() {
        XCTAssertEqual(compute(thermalState: .fair), .reduced)
    }

    func testOnBatteryAtFullChargeIsReduced() {
        // Any battery power → at least reduced, even at 100%.
        XCTAssertEqual(compute(isOnBattery: true, batteryLevel: 100), .reduced)
    }

    // MARK: - Policy ordering

    func testPolicyIsComparable() {
        // paused > minimal > reduced > full.
        XCTAssertGreaterThan(SakuraPlaybackPolicy.paused, .minimal)
        XCTAssertGreaterThan(SakuraPlaybackPolicy.minimal, .reduced)
        XCTAssertGreaterThan(SakuraPlaybackPolicy.reduced, .full)
    }
}
