import Foundation

final class TransitionDiagnostics {
    static let shared = TransitionDiagnostics()

    private let queue = DispatchQueue(label: "com.sakura.wallpaper.transition-diagnostics")
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    let logURL: URL

    private init() {
        let logsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/SakuraWallpaper", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        logURL = logsDirectory.appendingPathComponent("transition-diagnostics.log")
        rotateIfNeeded()
        log("diagnostics.started", details: "path=\(logURL.path)")
    }

    func log(_ event: String, details: String = "") {
        let timestamp = formatter.string(from: Date())
        let line = details.isEmpty
            ? "\(timestamp) \(event)\n"
            : "\(timestamp) \(event) \(details)\n"

        queue.async { [logURL] in
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: logURL.path),
               let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: logURL, options: .atomic)
            }
        }
    }

    func begin(_ event: String, details: String = "") -> DiagnosticToken {
        log("\(event).begin", details: details)
        return DiagnosticToken(event: event, start: CFAbsoluteTimeGetCurrent(), details: details)
    }

    func end(_ token: DiagnosticToken, details: String = "") {
        let elapsed = (CFAbsoluteTimeGetCurrent() - token.start) * 1000
        let duration = String(format: "duration=%.2fms", elapsed)
        let mergedDetails = [duration, token.details, details]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        log("\(token.event).end", details: mergedDetails)
    }

    private func rotateIfNeeded() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue > 1_000_000 else { return }
        try? FileManager.default.removeItem(at: logURL)
    }
}

struct DiagnosticToken {
    let event: String
    let start: CFAbsoluteTime
    let details: String
}
