// DesktopSyncService.swift — applies the extension's JPEG snapshots to the system desktop.
//
// The extension is sandboxed and cannot call NSWorkspace.setDesktopImageURL.
// It writes JPEG files to its container's Documents/snapshots/ directory; this
// service reads them and applies them via NSWorkspace so the lock screen and
// Mission Control show the same frame the extension is rendering.
//
// Ported from WallpaperManager.applyDesktopImage / applySystemDesktopWallpaper.
//
// Events that trigger a sync:
//   1. com.sakura.wallpaper.stateChanged   — extension advanced to a new video
//   2. com.apple.screenIsLocked            — apply before screen dims (lock screen preview)
//   3. com.apple.screensaver.didstart      — screensaver is about to show desktop briefly

import AppKit
import Foundation
import os

private let log = Logger(subsystem: "com.sakura.wallpaper", category: "DesktopSyncService")

@MainActor
final class DesktopSyncService {
    static let shared = DesktopSyncService()

    // Path to the extension container's snapshot directory. The extension writes here;
    // the app reads from here. The container must exist (extension has run at least once).
    private static let extensionSnapshotsURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Containers/com.sakura.wallpaper.extension")
            .appendingPathComponent("Data/Documents/snapshots")
    }()

    private var isObserving = false

    // MARK: - Start / Stop

    /// Start observing state-change and lock/screensaver notifications.
    /// Call once at app startup from SakuraApp or AppDelegate.
    func startObserving() {
        guard !isObserving else { return }
        isObserving = true

        // com.sakura.wallpaper.stateChanged — extension advanced the rotation.
        let darwinCenter = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            darwinCenter, observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let svc = Unmanaged<DesktopSyncService>.fromOpaque(observer).takeUnretainedValue()
                // Dispatch back to MainActor from the Darwin callback queue.
                Task { @MainActor in svc.applyAllDisplaySnapshots() }
            },
            SakuraNotification.stateChanged as CFString,
            nil, .deliverImmediately
        )

        // Lock screen / screensaver: apply the snapshot just before the screen locks so
        // the lock screen wallpaper preview matches what the extension is rendering.
        let distCenter = DistributedNotificationCenter.default()
        distCenter.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil, queue: .main
        ) { [weak self] _ in self?.applyAllDisplaySnapshots() }

        distCenter.addObserver(
            forName: NSNotification.Name("com.apple.screensaver.didstart"),
            object: nil, queue: .main
        ) { [weak self] _ in self?.applyAllDisplaySnapshots() }

        log.info("DesktopSyncService started")
    }

    // MARK: - Apply

    /// Read all per-display JPEG snapshots from the container and apply them via NSWorkspace.
    func applyAllDisplaySnapshots() {
        let snapDir = Self.extensionSnapshotsURL
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: snapDir, includingPropertiesForKeys: nil
        ) else {
            log.debug("No snapshot directory yet — extension hasn't run")
            return
        }

        // Snapshot filenames: "<displayID>-current.jpg" where displayID is a decimal UInt32.
        for file in files where file.lastPathComponent.hasSuffix("-current.jpg") {
            guard let displayIDStr = file.lastPathComponent.components(separatedBy: "-").first,
                  let displayID = UInt32(displayIDStr) else { continue }
            applySnapshot(at: file, toDisplay: displayID)
        }
    }

    // MARK: - Private

    private func applySnapshot(at url: URL, toDisplay displayID: UInt32) {
        // Map the raw displayID to an NSScreen.
        guard let screen = NSScreen.screens.first(where: { rawDisplayID(for: $0) == displayID }) else {
            log.debug("No NSScreen found for displayID \(displayID)")
            return
        }

        // NSWorkspace's desktop wallpaper options — no scaling info needed for a still JPEG;
        // the system will fit it to the display using the current scaling preference.
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: true
        ]

        do {
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
            log.debug("Applied desktop snapshot for display \(displayID): \(url.lastPathComponent)")
        } catch {
            log.error("setDesktopImageURL failed for display \(displayID): \(error)")
        }
    }

    /// Extract the CGDirectDisplayID from an NSScreen via its deviceDescription dictionary.
    private func rawDisplayID(for screen: NSScreen) -> UInt32 {
        // Private NSDeviceDescriptionKey: NSScreenNumber contains the CGDirectDisplayID.
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
            ?? CGMainDisplayID()
    }
}
