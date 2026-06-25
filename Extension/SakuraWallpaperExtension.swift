// SakuraWallpaperExtension.swift — extension entry point.
// Adapted from PhospheneExtension/PhospheneExtension.swift.
//
// Loads WallpaperExtensionKit via dlopen to register private XPC type classes,
// swizzles WallpaperSnapshotXPC.encodeWithCoder: to bypass the NSXPCCoder exact-
// class check, and wires up OS-level observers (display sleep/wake, screen lock).
//
// Callouts that depend on later phases are marked TODO and will be added as each
// phase lands:
//   Phase 2 — PowerMonitor / PlaybackPolicy → applyPolicy on renderers
//   Phase 3 — SakuraLibrary.shared.scan() + observePrefsChanges()

import AppKit
import ExtensionFoundation
import Foundation

@main
final class SakuraWallpaperExtension: NSObject, AppExtension {
    override required init() {
        super.init()

        // Load WallpaperExtensionKit at runtime so we can register real XPC type classes.
        // Private framework — keeping the handle open is required for vtable / C-function-pointer validity.
        let frameworkPath = "/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit"
        if let handle = dlopen(frameworkPath, RTLD_LAZY) {
            _ = handle // intentionally kept alive
            extensionLog("INIT (PID: \(ProcessInfo.processInfo.processIdentifier)) — WallpaperExtensionKit loaded")

            // Verify that every private class we depend on resolved after dlopen.
            // This is a startup self-check: failures here surface as one clear log line
            // rather than scattered downstream nil-guard failures on OS upgrades.
            verifyRuntimeLayout()

            // Patch WallpaperSnapshotXPC's encode so the snapshot reply reaches the Agent.
            // See swizzleSnapshotEncodeIfNeeded() for a full explanation.
            swizzleSnapshotEncodeIfNeeded()

            // TODO(Phase 3): SakuraLibrary.shared.scan()
            // TODO(Phase 3): observePrefsChanges()

            observeDisplaySleepWake()
            observeScreenLockState()
            observeLibraryChanges()

            // TODO(Phase 2): SakuraPowerMonitor.shared.startMonitoring() + policy Task

        } else {
            let err = String(cString: dlerror())
            extensionLog("INIT (PID: \(ProcessInfo.processInfo.processIdentifier)) — dlopen FAILED: \(err)")
        }
    }

    // MARK: - Runtime layout verification

    /// Log whether every private WallpaperExtensionKit class we bridge to is present.
    /// Does not fail the launch — per-call guards already fail closed — but it surfaces
    /// an unsupported OS/runtime layout in one clear line rather than as downstream failures.
    private func verifyRuntimeLayout() {
        let critical = [
            "WallpaperRemoteContextXPC",  // used in acquire() to return a context to the Agent
            "WallpaperSnapshotXPC",       // used in snapshot() to return a BMP to the picker
            "WallpaperCreationRequestXPC", // parsed in acquire() to extract size/displayID/choiceID
            "WallpaperSettingsViewModelsXPC", // used in provideSettingsViewModels()
            "WallpaperIDXPC",             // parsed in acquire() and invalidate() for the wallpaperID UUID
        ]
        let missing = critical.filter { objc_getClass($0) == nil }
        if missing.isEmpty {
            extensionLog("  [SelfCheck] Runtime layout OK — all \(critical.count) critical classes present")
        } else {
            extensionLog("  [SelfCheck] UNSUPPORTED RUNTIME — missing: \(missing.joined(separator: ", ")). Rendering/snapshots may be degraded.")
        }
    }

    // MARK: - NSXPCCoder ISA swap swizzle

    /// Patch WallpaperSnapshotXPC's encodeWithCoder: to bypass the exact NSXPCCoder class check.
    ///
    /// WallpaperSnapshotXPC.encodeWithCoder: checks `type(of: coder) == NSXPCCoder.self`, but the
    /// actual coder is NSXPCEncoder (a subclass). Without this fix, encoding is a silent no-op
    /// and the Agent receives no snapshot data — showing grey during transitions.
    ///
    /// Private API: temporarily set the coder's ISA to NSXPCCoder before calling the original
    /// encode, then restore it. Both classes implement encodeXPCObject:forKey:, so dispatch works.
    /// Copied from PhospheneExtension/PhospheneExtension.swift — identical for macOS 26.
    private func swizzleSnapshotEncodeIfNeeded() {
        guard let snapshotClass = objc_getClass("WallpaperSnapshotXPC") as? AnyClass else {
            extensionLog("  [Swizzle] WallpaperSnapshotXPC not found")
            return
        }

        let sel = NSSelectorFromString("encodeWithCoder:")
        guard let origMethod = class_getInstanceMethod(snapshotClass, sel) else {
            extensionLog("  [Swizzle] encodeWithCoder: not found on WallpaperSnapshotXPC")
            return
        }

        let origIMP = method_getImplementation(origMethod)
        typealias EncodeFunc = @convention(c) (AnyObject, Selector, NSCoder) -> Void
        let origFunc = unsafeBitCast(origIMP, to: EncodeFunc.self)

        guard let nsxpcCoderClass = NSClassFromString("NSXPCCoder") else {
            extensionLog("  [Swizzle] NSXPCCoder class not found")
            return
        }

        // Private API: ISA swap. object_setClass is safe here because NSXPCCoder and
        // NSXPCEncoder share the same method implementations — we're only changing
        // which class the type(of:) check sees, not the actual vtable.
        let block: @convention(block) (AnyObject, NSCoder) -> Void = { obj, coder in
            let origClass: AnyClass = object_getClass(coder)!
            object_setClass(coder, nsxpcCoderClass)
            origFunc(obj, sel, coder)
            object_setClass(coder, origClass)
        }
        let newIMP = imp_implementationWithBlock(block)
        method_setImplementation(origMethod, newIMP)
        extensionLog("  [Swizzle] Patched WallpaperSnapshotXPC encodeWithCoder:")
    }

    // MARK: - Display sleep / wake

    /// Pause all renderers when displays sleep and recompute policy on wake.
    private func observeDisplaySleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil, queue: .main
        ) { _ in
            SakuraExtensionState.shared.isDisplayAsleep = true
            // TODO(Phase 2): SakuraExtensionState.shared.forEachRenderer { $0.applyPolicy(.paused) }
            extensionLog("[Extension] Displays asleep — will pause all renderers (Phase 2)")
        }
        center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil, queue: .main
        ) { _ in
            SakuraExtensionState.shared.isDisplayAsleep = false
            // TODO(Phase 2): SakuraWallpaperExtension.recomputeAndApplyPolicy()
            extensionLog("[Extension] Displays awake — will recompute policy (Phase 2)")

            // Recompute after 1 s to catch pending WallpaperAgent presentation mode updates.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                // TODO(Phase 2): SakuraWallpaperExtension.recomputeAndApplyPolicy()
            }
        }
    }

    // MARK: - Screen lock state

    /// Track lock screen state via distributed notifications from loginwindow.
    /// This pre-empts the WallpaperAgent presentation mode update and fixes the race
    /// where a video paused on the desktop doesn't resume on the lock screen after lid open.
    private func observeScreenLockState() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(
            forName: .init("com.apple.screenIsLocked"),
            object: nil, queue: .main
        ) { _ in
            SakuraExtensionState.shared.isScreenLocked = true
            extensionLog("[Extension] Screen locked")
        }
        dnc.addObserver(
            forName: .init("com.apple.screenIsUnlocked"),
            object: nil, queue: .main
        ) { _ in
            SakuraExtensionState.shared.isScreenLocked = false
            // TODO(Phase 2): SakuraWallpaperExtension.recomputeAndApplyPolicy()
            extensionLog("[Extension] Screen unlocked — will recompute policy (Phase 2)")
        }
    }

    // MARK: - Library changes

    /// Observe the Darwin notification posted by the app when videos are added or removed.
    private func observeLibraryChanges() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, _, _, _, _ in
                // TODO(Phase 3): SakuraLibrary.shared.scan()
                extensionLog("[Extension] libraryChanged notification received — Phase 3 will re-scan")
            },
            SakuraNotification.libraryChanged as CFString,
            nil,
            .deliverImmediately
        )
    }

    // MARK: - AppExtension

    var configuration: some AppExtensionConfiguration {
        WallpaperExtensionConfig()
    }
}
