// PathSafetyTests.swift — tests for the path containment and ID validation guards.
// Phase 9: new tests for Phase 3 PathSafety.swift.
//
// These tests verify that the security gates in SakuraLibrary.scan() reject
// path-traversal and injection attempts.

import XCTest
@testable import SakuraWallpaperCore

final class PathSafetyTests: XCTestCase {

    // MARK: - isValidEntryID

    func testValidUUIDAccepted() {
        XCTAssertTrue(PathSafety.isValidEntryID("A1B2C3D4-0000-0000-0000-000000000000"))
    }

    func testLowercaseUUIDRejected() {
        // Entry IDs are uppercase-UUID form — lowercase should fail.
        XCTAssertFalse(PathSafety.isValidEntryID("a1b2c3d4-0000-0000-0000-000000000000"))
    }

    func testArbitraryStringRejected() {
        XCTAssertFalse(PathSafety.isValidEntryID("../secret"))
        XCTAssertFalse(PathSafety.isValidEntryID(""))
        XCTAssertFalse(PathSafety.isValidEntryID("notauuid"))
    }

    // MARK: - isSafeComponent

    func testSafeFilenameAccepted() {
        XCTAssertTrue(PathSafety.isSafeComponent("video.mp4"))
        XCTAssertTrue(PathSafety.isSafeComponent("my-video-2024.mov"))
    }

    func testPathTraversalRejected() {
        XCTAssertFalse(PathSafety.isSafeComponent("../../../etc/passwd"))
        XCTAssertFalse(PathSafety.isSafeComponent("subdir/video.mp4"))
    }

    func testEmptyNameRejected() {
        XCTAssertFalse(PathSafety.isSafeComponent(""))
    }

    func testDotOnlyNamesRejected() {
        XCTAssertFalse(PathSafety.isSafeComponent("."))
        XCTAssertFalse(PathSafety.isSafeComponent(".."))
    }

    // MARK: - contained

    func testChildInsideBaseAccepted() {
        let base  = URL(fileURLWithPath: "/some/base/dir")
        let child = URL(fileURLWithPath: "/some/base/dir/sub/file.mp4")
        XCTAssertTrue(PathSafety.contained(child, in: base))
    }

    func testChildEqualsBaseAccepted() {
        let base = URL(fileURLWithPath: "/some/base/dir")
        XCTAssertTrue(PathSafety.contained(base, in: base))
    }

    func testChildOutsideBaseRejected() {
        let base   = URL(fileURLWithPath: "/some/base/dir")
        let escape = URL(fileURLWithPath: "/some/other/dir/file.mp4")
        XCTAssertFalse(PathSafety.contained(escape, in: base))
    }

    func testTraversalAboveBaseRejected() {
        let base      = URL(fileURLWithPath: "/some/base/dir")
        let traversal = URL(fileURLWithPath: "/some/base/dir/../../secret")
        XCTAssertFalse(PathSafety.contained(traversal, in: base))
    }
}
