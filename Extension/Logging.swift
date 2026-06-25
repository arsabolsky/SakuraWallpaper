// Logging.swift — persistent file-backed logging for the extension process.
// Copied from PhospheneExtension/Logging.swift; adapted log path to ~/Documents/sakura-extension.log.
// The extension writes here because os_log entries aren't easily tailed during development.

import Foundation
import os

/// Maximum log file size before rotation (1 MB).
private let maxLogSize: UInt64 = 1_024 * 1_024

/// Number of rotated log copies to keep.
private let maxRotatedCopies = 2

private let logURL: URL = {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("sakura-extension.log")
}()

/// Persistent file handle for log writing, protected by an unfair lock.
private let logLock = OSAllocatedUnfairLock(initialState: nil as FileHandle?)

/// Cached formatter — ISO8601DateFormatter is thread-safe with immutable config.
/// `nonisolated(unsafe)` because ISO8601DateFormatter doesn't conform to Sendable,
/// but it's effectively immutable after initialization.
private nonisolated(unsafe) let logDateFormatter = ISO8601DateFormatter()

/// Get or create the persistent log file handle. Rotates on size overflow.
private func getLogHandle() -> FileHandle? {
    logLock.withLock { handle in
        if let h = handle {
            if (try? h.seekToEnd()) ?? 0 >= maxLogSize {
                try? h.close()
                rotateLog()
                return openLogHandle()
            }
            return h
        }
        let h = openLogHandle()
        handle = h
        return h
    }
}

private func openLogHandle() -> FileHandle? {
    guard let h = try? FileHandle(forWritingTo: logURL) else {
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        return try? FileHandle(forWritingTo: logURL)
    }
    _ = try? h.seekToEnd()
    return h
}

private func rotateLog() {
    let fm = FileManager.default
    let dir = logURL.deletingLastPathComponent()
    let baseName = logURL.deletingPathExtension().lastPathComponent
    let ext = logURL.pathExtension

    let oldestURL = dir.appendingPathComponent("\(baseName).\(maxRotatedCopies).\(ext)")
    try? fm.removeItem(at: oldestURL)

    if maxRotatedCopies > 1 {
        for i in stride(from: maxRotatedCopies - 1, through: 1, by: -1) {
            let oldURL = dir.appendingPathComponent("\(baseName).\(i).\(ext)")
            let newURL = dir.appendingPathComponent("\(baseName).\(i + 1).\(ext)")
            if fm.fileExists(atPath: oldURL.path) { try? fm.moveItem(at: oldURL, to: newURL) }
        }
    }

    let rotatedURL = dir.appendingPathComponent("\(baseName).1.\(ext)")
    if fm.fileExists(atPath: logURL.path) { try? fm.moveItem(at: logURL, to: rotatedURL) }

    // Remove any stale copies from older buggy retention behavior.
    let staleStart = maxRotatedCopies + 1
    for i in staleStart ... staleStart + 2 {
        let staleURL = dir.appendingPathComponent("\(baseName).\(i).\(ext)")
        if fm.fileExists(atPath: staleURL.path) { try? fm.removeItem(at: staleURL) }
    }
}

/// Recursively dump an object's Mirror for debugging XPC types.
func dumpMirror(_ obj: Any, label: String = "root", depth: Int = 3, indent: Int = 0) {
    let prefix = String(repeating: "  ", count: indent)
    let mirror = Mirror(reflecting: obj)
    extensionLog("\(prefix)[\(label)] type=\(type(of: obj)) children=\(mirror.children.count)")
    guard depth > 0 else { return }
    for child in mirror.children {
        let childLabel = child.label ?? "?"
        let childValue = child.value
        let desc = String(describing: childValue).prefix(200)
        extensionLog("\(prefix)  .\(childLabel) = \(desc)")
        let childMirror = Mirror(reflecting: childValue)
        if childMirror.children.count > 0, !(childValue is String), !(childValue is Data), !(childValue is URL) {
            dumpMirror(childValue, label: childLabel, depth: depth - 1, indent: indent + 2)
        }
    }
}

/// Write a timestamped line to the extension log file.
func extensionLog(_ message: String) {
    let ts = logDateFormatter.string(from: Date())
    let line = "[\(ts)] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    guard let handle = getLogHandle() else {
        try? data.write(to: logURL, options: .atomic)
        return
    }
    handle.write(data)
}
