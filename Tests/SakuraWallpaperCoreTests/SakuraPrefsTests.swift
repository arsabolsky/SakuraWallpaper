// SakuraPrefsTests.swift — round-trip JSON encode/decode tests for the prefs model.
// Phase 9: new tests for Phase 3 types.

import XCTest
@testable import SakuraWallpaperCore

final class SakuraPrefsTests: XCTestCase {

    // MARK: - SakuraPrefs round-trip

    func testSakuraPrefsRoundTrip() throws {
        var prefs = SakuraPrefs()
        prefs.userPaused = true
        prefs.alwaysPauseDesktop = false
        prefs.pauseWhenOccluded = true
        prefs.newScreenPolicy = "inheritSyncGroup"
        prefs.wallpaperHistory = ["uuid-1", "uuid-2"]

        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(SakuraPrefs.self, from: data)

        XCTAssertEqual(decoded.userPaused, true)
        XCTAssertEqual(decoded.alwaysPauseDesktop, false)
        XCTAssertEqual(decoded.pauseWhenOccluded, true)
        XCTAssertEqual(decoded.newScreenPolicy, "inheritSyncGroup")
        XCTAssertEqual(decoded.wallpaperHistory, ["uuid-1", "uuid-2"])
    }

    // MARK: - SakuraDisplayConfig round-trip

    func testSakuraDisplayConfigRoundTrip() throws {
        var config = SakuraDisplayConfig()
        config.entryID = "DEADBEEF-0000-0000-0000-000000000000"
        config.rotationIntervalMinutes = 30
        config.isRotationEnabled = true
        config.isShuffleMode = true
        config.isFolderMode = true

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SakuraDisplayConfig.self, from: data)

        XCTAssertEqual(decoded.entryID, "DEADBEEF-0000-0000-0000-000000000000")
        XCTAssertEqual(decoded.rotationIntervalMinutes, 30)
        XCTAssertTrue(decoded.isRotationEnabled)
        XCTAssertTrue(decoded.isShuffleMode)
        XCTAssertTrue(decoded.isFolderMode)
    }

    // MARK: - SakuraSyncGroup round-trip

    func testSakuraSyncGroupRoundTrip() throws {
        let group = SakuraSyncGroup(
            groupID: "group-1",
            displayIDs: ["100", "200"],
            rotationIntervalMinutes: 10,
            isShuffleMode: false
        )

        let data = try JSONEncoder().encode(group)
        let decoded = try JSONDecoder().decode(SakuraSyncGroup.self, from: data)

        XCTAssertEqual(decoded.groupID, "group-1")
        XCTAssertEqual(decoded.displayIDs, ["100", "200"])
        XCTAssertEqual(decoded.rotationIntervalMinutes, 10)
        XCTAssertFalse(decoded.isShuffleMode)
    }

    // MARK: - Defaults are stable

    func testDefaultPrefsEncodeDecodeWithoutLoss() throws {
        let original = SakuraPrefs()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SakuraPrefs.self, from: data)

        XCTAssertEqual(decoded.userPaused, original.userPaused)
        XCTAssertEqual(decoded.newScreenPolicy, original.newScreenPolicy)
        XCTAssertEqual(decoded.wallpaperHistory, original.wallpaperHistory)
        XCTAssertEqual(decoded.syncGroups.count, original.syncGroups.count)
    }

    // MARK: - perDisplayConfig keyed by display ID

    func testPerDisplayConfigKeying() throws {
        var prefs = SakuraPrefs()
        var cfg = SakuraDisplayConfig()
        cfg.entryID = "video-uuid"
        prefs.perDisplayConfig["12345"] = cfg

        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(SakuraPrefs.self, from: data)

        XCTAssertEqual(decoded.perDisplayConfig["12345"]?.entryID, "video-uuid")
    }
}
