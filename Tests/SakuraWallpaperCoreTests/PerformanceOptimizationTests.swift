import XCTest
@testable import SakuraWallpaperCore

final class PerformanceOptimizationTests: XCTestCase {
    func testPlaylistBuilderUsesCacheUntilCleared() throws {
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaylistCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folderURL) }
        PlaylistBuilder.clearCache()
        defer { PlaylistBuilder.clearCache() }

        let firstFile = folderURL.appendingPathComponent("a.jpg")
        let secondFile = folderURL.appendingPathComponent("b.jpg")
        FileManager.default.createFile(atPath: firstFile.path, contents: Data())

        let firstScan = try PlaylistBuilder.collectMediaFiles(in: folderURL, includeSubfolders: false)
        FileManager.default.createFile(atPath: secondFile.path, contents: Data())
        let cachedScan = try PlaylistBuilder.collectMediaFiles(in: folderURL, includeSubfolders: false)

        XCTAssertEqual(firstScan.map(\.lastPathComponent), ["a.jpg"])
        XCTAssertEqual(cachedScan.map(\.lastPathComponent), ["a.jpg"])

        PlaylistBuilder.clearCache()
        let refreshedScan = try PlaylistBuilder.collectMediaFiles(in: folderURL, includeSubfolders: false)
        XCTAssertEqual(refreshedScan.map(\.lastPathComponent), ["a.jpg", "b.jpg"])
    }

    func testAsyncWorkLimiterNeverExceedsConcurrentLimit() {
        let limiter = AsyncWorkLimiter(maxConcurrent: 2)
        let allDone = expectation(description: "all work completed")
        allDone.expectedFulfillmentCount = 5

        let lock = NSLock()
        var active = 0
        var peakActive = 0

        for _ in 0..<5 {
            limiter.schedule { finish in
                lock.lock()
                active += 1
                peakActive = max(peakActive, active)
                lock.unlock()

                DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) {
                    lock.lock()
                    active -= 1
                    lock.unlock()
                    finish()
                    allDone.fulfill()
                }
            }
        }

        wait(for: [allDone], timeout: 2)
        XCTAssertLessThanOrEqual(peakActive, 2)
    }
}
