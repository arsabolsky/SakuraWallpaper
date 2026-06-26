// SakuraBMPCache.swift — BMP snapshot cache for zero-gray wallpaper transitions.
// Adapted from PhospheneExtension/BMPCache.swift.
// Changes: WallpaperState → SakuraExtensionState, log prefix updated.
//
// Without a BMP cache, the desktop shows gray for ~1 minute on every wallpaper
// switch while the extension restarts and the renderer pipeline warms up.
// WallpaperExtensionKit's built-in VideoPlayer writes these automatically; since we
// use raw AVSampleBufferDisplayLayer, we must write them ourselves.
//
// Format matches Apple's cache files: BITMAPINFOHEADER, 24bpp BGR top-down.
// The cacheDirectory URL is security-scoped (passed via XPC from WallpaperAgent in acquire).

import AVFoundation
import CryptoKit
import Foundation

/// Load the most recent cached BMP from the Agent's cache directory as a CGImage.
/// Set as rootLayer.contents immediately in acquire() so the display isn't blank
/// during the async renderer startup. Each display passes its own per-context choice
/// so the correct frame is shown — never use the process-wide currentVideoID here.
func loadCachedSnapshotImage(forChoice videoID: String?) -> CGImage? {
    guard let cacheDir = SakuraExtensionState.shared.cacheDirectoryURL else { return nil }

    let gained = cacheDir.startAccessingSecurityScopedResource()
    defer { if gained { cacheDir.stopAccessingSecurityScopedResource() } }

    guard let contents = try? FileManager.default.contentsOfDirectory(
        at: cacheDir, includingPropertiesForKeys: nil
    ) else { return nil }

    let bmps = contents.filter { $0.pathExtension == "bmp" }
    let bmpURL: URL?
    if let videoID {
        let hash = sakuraVideoHash(for: videoID)
        bmpURL = bmps.first { $0.lastPathComponent.hasPrefix(hash) } ?? bmps.first
    } else {
        bmpURL = bmps.first
    }

    guard let url = bmpURL,
          let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else { return nil }

    extensionLog("[BMPCache] Loaded cached snapshot: \(url.lastPathComponent) (\(img.width)x\(img.height))")
    return img
}

/// Write a BMP snapshot of the video's first frame to the Agent's cache directory.
/// Keyed by videoID so each video gets its own file; WallpaperAgent uses these to
/// fill the desktop immediately on the next startup without waiting for the renderer.
func writeBMPSnapshot(
    videoURL: URL,
    videoID: String? = nil,
    displayPixelWidth: Int,
    displayPixelHeight: Int
) async {
    guard let cacheDir = SakuraExtensionState.shared.cacheDirectoryURL else {
        extensionLog("[BMPCache] No cacheDirectoryURL — skipping BMP write")
        return
    }
    let gained = cacheDir.startAccessingSecurityScopedResource()
    defer { if gained { cacheDir.stopAccessingSecurityScopedResource() } }
    guard gained else {
        extensionLog("[BMPCache] Failed to acquire security-scoped access to cache dir")
        return
    }

    let hashHex = sakuraVideoHash(for: videoID ?? videoURL.lastPathComponent)

    // Skip if an existing BMP already covers this size — avoids redundant disk I/O on fast loops.
    if let existing = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) {
        for bmp in existing where bmp.pathExtension == "bmp" && bmp.lastPathComponent.hasPrefix(hashHex) {
            let parts = bmp.deletingPathExtension().lastPathComponent.components(separatedBy: "-")
            if parts.count == 5,
               let w = Int(parts[1]), let h = Int(parts[2]),
               w == displayPixelWidth, h == displayPixelHeight {
                extensionLog("[BMPCache] BMP already exists for \(videoID ?? "?") at \(w)x\(h), skipping")
                return
            }
        }
    }

    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
    generator.appliesPreferredTrackTransform = true
    let cgImage: CGImage
    do {
        cgImage = try await generator.image(at: .zero).image
    } catch {
        extensionLog("[BMPCache] Failed to get video frame: \(error)")
        return
    }

    let width = cgImage.width, height = cgImage.height
    let bytesPerPx = 3   // 24bpp BGR
    let rawRowBytes = width * bytesPerPx
    let paddedRowBytes = (rawRowBytes + 3) & ~3  // 4-byte aligned rows
    let pixelDataSize = paddedRowBytes * height

    let bgraRowBytes = width * 4
    var bgra = Data(count: bgraRowBytes * height)
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    let rendered = bgra.withUnsafeMutableBytes { rawBuf -> Bool in
        guard let ctx = CGContext(
            data: rawBuf.baseAddress,
            width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: bgraRowBytes, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return false }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard rendered else { extensionLog("[BMPCache] CGContext render failed"); return }

    // Convert BGRA → BGR24 with row padding
    var pixels = Data(count: pixelDataSize)
    bgra.withUnsafeBytes { src in
        pixels.withUnsafeMutableBytes { dst in
            let s = src.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let d = dst.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for y in 0 ..< height {
                for x in 0 ..< width {
                    let si = y * bgraRowBytes + x * 4
                    let di = y * paddedRowBytes + x * 3
                    d[di] = s[si]; d[di+1] = s[si+1]; d[di+2] = s[si+2]
                }
            }
        }
    }

    // BMP file: 14-byte file header + 40-byte BITMAPINFOHEADER + pixel data
    let headerSize = 14 + 40
    let fileSize = headerSize + pixelDataSize
    var bmp = Data(count: headerSize)
    bmp[0] = 0x42; bmp[1] = 0x4D  // "BM" magic
    bmpLE32(&bmp, at: 2, v: UInt32(fileSize))
    bmpLE32(&bmp, at: 10, v: UInt32(headerSize))
    let d = 14  // start of BITMAPINFOHEADER
    bmpLE32(&bmp, at: d, v: 40)
    bmpLE32(&bmp, at: d+4, v: UInt32(bitPattern: Int32(width)))
    bmpLE32(&bmp, at: d+8, v: UInt32(bitPattern: Int32(-height)))  // negative = top-down
    bmpLE16(&bmp, at: d+12, v: 1); bmpLE16(&bmp, at: d+14, v: 24) // planes, bpp
    bmpLE32(&bmp, at: d+16, v: 0)                                  // BI_RGB
    bmpLE32(&bmp, at: d+20, v: UInt32(pixelDataSize))
    bmp.append(pixels)

    // Remove old BMP for same video
    if let contents = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) {
        for f in contents where f.pathExtension == "bmp" && f.lastPathComponent.hasPrefix(hashHex) {
            try? FileManager.default.removeItem(at: f)
        }
    }

    let ts = String(format: "%016llx", Date().timeIntervalSinceReferenceDate.bitPattern)
    let filename = "\(hashHex)-\(displayPixelWidth)-\(displayPixelHeight)-0-\(ts).bmp"
    let bmpURL = cacheDir.appendingPathComponent(filename)
    do {
        try bmp.write(to: bmpURL, options: .atomic)
        // WallpaperAgent reads cacheVersion.db to know the cache is valid.
        try Data("{\"version\":2}".utf8).write(
            to: cacheDir.appendingPathComponent("cacheVersion.db"), options: .atomic)
        extensionLog("[BMPCache] Wrote \(bmp.count) bytes → \(filename)")
    } catch {
        extensionLog("[BMPCache] Write failed: \(error)")
    }
}

// MARK: - Helpers

private func sakuraVideoHash(for id: String) -> String {
    SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func bmpLE32(_ data: inout Data, at i: Int, v: UInt32) {
    data[i] = UInt8(v & 0xFF); data[i+1] = UInt8((v>>8) & 0xFF)
    data[i+2] = UInt8((v>>16) & 0xFF); data[i+3] = UInt8((v>>24) & 0xFF)
}
private func bmpLE16(_ data: inout Data, at i: Int, v: UInt16) {
    data[i] = UInt8(v & 0xFF); data[i+1] = UInt8((v>>8) & 0xFF)
}
