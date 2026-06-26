// SakuraSnapshotCreation.swift — IOSurface snapshot for System Settings wallpaper picker.
// Adapted from PhospheneExtension/SnapshotCreation.swift.
// Changes: WallpaperState → SakuraExtensionState, findVideoURL uses SakuraDiscovery.
//
// Called from SakuraXPCHandler.snapshot() to return a WallpaperSnapshotXPC containing
// one video frame. The picker uses this to render thumbnails in System Settings.
//
// AVSampleBufferDisplayLayer exposes its current frame via IOSurface, not CGImage.
// Reading the surface directly avoids a GPU readback through CGImage.

import AVFoundation
import CoreMedia
@preconcurrency import IOSurface

/// Create a WallpaperSnapshotXPC wrapping an IOSurface video frame.
///
/// If `currentTime` is valid, captures the frame the renderer last displayed —
/// so the picker thumbnail matches exactly what the user sees on their desktop.
/// Falls back to a random time within the video to avoid always returning frame 0.
func createSnapshotViaRuntime(currentTime: CMTime? = nil) async -> AnyObject? {
    guard let videoURL = findVideoURL() else {
        extensionLog("[Snapshot] No video file found")
        return nil
    }

    let asset = AVURLAsset(url: videoURL)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true

    let requestTime: CMTime
    if let currentTime, currentTime.isValid, currentTime.seconds > 0 {
        requestTime = currentTime
    } else {
        do {
            let duration = try await asset.load(.duration)
            if duration.isValid, duration.seconds > 0 {
                let offset = Double.random(in: 0 ..< duration.seconds)
                requestTime = CMTime(seconds: offset, preferredTimescale: duration.timescale)
            } else {
                requestTime = .zero
            }
        } catch {
            requestTime = .zero
        }
    }

    let image: CGImage
    do {
        image = try await generator.image(at: requestTime).image
    } catch {
        extensionLog("[Snapshot] Failed to get video frame at \(requestTime.seconds)s: \(error)")
        return nil
    }

    guard let snapshotXPC = renderSnapshotToIOSurface(image: image) else { return nil }
    extensionLog("[Snapshot] Created WallpaperSnapshotXPC \(image.width)x\(image.height)")
    return snapshotXPC
}

/// Render a CGImage to an IOSurface and wrap it in a WallpaperSnapshotXPC.
private func renderSnapshotToIOSurface(image: CGImage) -> AnyObject? {
    let width = image.width, height = image.height

    let surfaceProps: [IOSurfacePropertyKey: any Sendable] = [
        .width: width, .height: height,
        .bytesPerElement: 4,
        .pixelFormat: 0x4247_5241, // 'BGRA'
    ]
    guard let surface = IOSurface(properties: surfaceProps) else {
        extensionLog("[Snapshot] Failed to create IOSurface")
        return nil
    }

    surface.lock(options: [], seed: nil)
    let drawn: Bool
    if let ctx = CGContext(
        data: surface.baseAddress,
        width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: surface.bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) {
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        drawn = true
    } else {
        drawn = false
    }
    surface.unlock(options: [], seed: nil)
    guard drawn else {
        extensionLog("[Snapshot] Failed to create CGContext for IOSurface")
        return nil
    }

    return createSnapshotXPC(surface: surface)
}
