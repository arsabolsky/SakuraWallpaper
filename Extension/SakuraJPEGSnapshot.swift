// SakuraJPEGSnapshot.swift — write a JPEG still-frame for DesktopSyncService.
//
// The extension is sandboxed and cannot call NSWorkspace.setDesktopImageURL.
// Instead, after each rotation advance, it writes a JPEG to:
//   ~/Documents/snapshots/<displayID>-current.jpg
// (where ~ is the extension container). The app-side DesktopSyncService observes
// com.sakura.wallpaper.stateChanged and applies the JPEG via NSWorkspace.
//
// Using AVAssetImageGenerator here (not the live display layer) so we always capture
// an in-video frame at a deterministic time and the file is self-contained — the app
// doesn't need to know anything about the video file format.

import AVFoundation
import ImageIO

/// Write a JPEG thumbnail-size still from the video's first frame to `destination`.
/// Overwrites atomically so the app-side reader never sees a partial write.
func writeJPEGSnapshot(videoURL: URL, to destination: URL) async {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 1_920, height: 1_080)

    let cgImage: CGImage
    do {
        cgImage = try await generator.image(at: .zero).image
    } catch {
        extensionLog("[JPEGSnapshot] Frame capture failed for \(videoURL.lastPathComponent): \(error)")
        return
    }

    let tmpURL = destination.deletingLastPathComponent()
        .appendingPathComponent(".\(destination.lastPathComponent).tmp")

    guard let dest = CGImageDestinationCreateWithURL(tmpURL as CFURL, "public.jpeg" as CFString, 1, nil) else {
        extensionLog("[JPEGSnapshot] CGImageDestination creation failed")
        return
    }
    // 0.90 quality — high enough to not introduce artefacts that look wrong on the lock screen.
    CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.90] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else {
        extensionLog("[JPEGSnapshot] CGImageDestinationFinalize failed")
        try? FileManager.default.removeItem(at: tmpURL)
        return
    }

    do {
        // Atomic rename so DesktopSyncService never sees a half-written file.
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: tmpURL)
        extensionLog("[JPEGSnapshot] Wrote → \(destination.lastPathComponent)")
    } catch {
        extensionLog("[JPEGSnapshot] Atomic rename failed: \(error)")
        try? FileManager.default.removeItem(at: tmpURL)
    }
}
