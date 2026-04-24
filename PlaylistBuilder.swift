import Foundation

enum PlaylistBuilder {
    private struct CacheKey: Hashable {
        let path: String
        let includeSubfolders: Bool
    }

    private static var cache: [CacheKey: [URL]] = [:]
    private static let cacheLock = NSLock()

    static func collectMediaFiles(in folderURL: URL, includeSubfolders: Bool) throws -> [URL] {
        let key = CacheKey(path: folderURL.standardizedFileURL.path, includeSubfolders: includeSubfolders)
        if let cached = cachedFiles(for: key) {
            return cached
        }

        let manager = FileManager.default
        let files: [URL]
        if includeSubfolders {
            let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isHiddenKey]
            guard let enumerator = manager.enumerator(at: folderURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
                return []
            }
            var collectedFiles: [URL] = []
            for case let fileURL as URL in enumerator {
                let values = try fileURL.resourceValues(forKeys: Set(keys))
                if values.isDirectory == true { continue }
                if values.isHidden == true { continue }
                if MediaType.detect(fileURL) != .unsupported {
                    collectedFiles.append(fileURL)
                }
            }
            files = collectedFiles.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
        } else {
            files = try manager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                .filter { MediaType.detect($0) != .unsupported }
                .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        }

        store(files, for: key)
        return files
    }

    static func clearCache() {
        cacheLock.lock()
        cache.removeAll()
        cacheLock.unlock()
    }

    static func nextIndex(currentIndex: Int, itemCount: Int, shuffle: Bool, randomIndex: (() -> Int)? = nil) -> Int {
        guard itemCount > 0 else { return 0 }
        if shuffle {
            if itemCount == 1 { return 0 }
            let candidate = randomIndex?() ?? Int.random(in: 0..<itemCount)
            if candidate == currentIndex {
                return (candidate + 1) % itemCount
            }
            return candidate
        }
        return (currentIndex + 1) % itemCount
    }

    private static func cachedFiles(for key: CacheKey) -> [URL]? {
        cacheLock.lock()
        let files = cache[key]
        cacheLock.unlock()
        return files
    }

    private static func store(_ files: [URL], for key: CacheKey) {
        cacheLock.lock()
        cache[key] = files
        cacheLock.unlock()
    }
}
