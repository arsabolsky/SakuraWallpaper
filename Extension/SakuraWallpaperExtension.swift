// SakuraWallpaperExtension.swift — extension entry point.
// Adapted from PhospheneExtension/PhospheneExtension.swift.
//
// Loads WallpaperExtensionKit via dlopen to register private XPC type classes,
// swizzles WallpaperSnapshotXPC.encodeWithCoder: to bypass the NSXPCCoder exact-
// class check, and wires up OS-level observers (display sleep/wake, screen lock).
//
// All phases are complete; all callouts have been filled in.

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

            // Scan the video library so entries are available before the first acquire().
            SakuraLibrary.shared.scan()
            // Start observing prefs changes so rotation config reloads when the app writes.
            SakuraPrefsProvider.shared.observeChanges()

            observeDisplaySleepWake()
            observeScreenLockState()
            observeLibraryChanges()

            // Start the power monitor and spawn a Task that recomputes policy whenever
            // any power condition changes (thermal, battery, brightness, game mode).
            SakuraPowerMonitor.shared.startMonitoring()
            Task.detached(priority: .utility) {
                for await _ in SakuraPowerMonitor.shared.stateChanges() {
                    SakuraWallpaperExtension.recomputeAndApplyPolicy()
                }
            }

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
            // Displays asleep — pause all renderers immediately without animation.
            // SakuraPowerMonitor will also fire a state change (brightness drops to zero),
            // but this direct path ensures renderers pause even without a backlight event.
            SakuraExtensionState.shared.forEachRenderer { $0.applyPolicy(.paused) }
            extensionLog("[Extension] Displays asleep — all renderers paused")
        }
        center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil, queue: .main
        ) { _ in
            SakuraExtensionState.shared.isDisplayAsleep = false
            // Recompute immediately so renderers resume if conditions allow.
            SakuraWallpaperExtension.recomputeAndApplyPolicy()
            // Recompute again after 1 s to catch any delayed WallpaperAgent presentation
            // mode update that arrives after screensDidWake.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                SakuraWallpaperExtension.recomputeAndApplyPolicy()
            }
            extensionLog("[Extension] Displays awake — policy recomputed")
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
            // Screen unlocked — resume renderers with animation (2s ease-in, Apple-style).
            SakuraWallpaperExtension.recomputeAndApplyPolicy(animated: true)
            extensionLog("[Extension] Screen unlocked — policy recomputed (animated)")
        }
    }

    // MARK: - Policy recompute

    /// Compute the correct SakuraPlaybackPolicy from all current system state and
    /// apply it to every active renderer. Safe to call from any queue — reads state
    /// under the OSAllocatedUnfairLock and calls forEachRenderer outside the lock.
    ///
    /// `animated`: pass true when transitioning to/from the lock screen so the
    /// renderer uses the 2s ease-in-out ramp. All other callers use false.
    ///
    /// Phase 3 will add SakuraPrefs reading to supply alwaysPauseDesktop,
    /// pauseWhenOccluded, desktopOccluded, and userPaused. Until then these
    /// default to off/false so no rendering is unnecessarily suppressed.
    static func recomputeAndApplyPolicy(animated: Bool = false) {
        let state = SakuraExtensionState.shared
        let power = SakuraPowerMonitor.shared.currentState

        let prefs = SakuraPrefsProvider.shared

        let policy = SakuraPlaybackPolicy.compute(
            presentationMode: state.presentationMode,
            activityState: state.activityState,
            userPaused: prefs.userPaused,
            alwaysPauseDesktop: prefs.alwaysPauseDesktop,
            pauseWhenOccluded: prefs.pauseWhenOccluded,
            desktopOccluded: prefs.desktopOccluded,
            powerState: power
        )

        extensionLog("[Policy] \(policy) (mode: \(state.presentationMode), battery: \(power.batteryLevel)%, thermal: \(power.thermalState.rawValue))")
        state.forEachRenderer { $0.applyPolicy(policy, animated: animated) }
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
                // Re-scan the library on the Darwin notification queue.
                // scan() is O(directory listing) and safe to run on any queue.
                SakuraLibrary.shared.scan()
                extensionLog("[Extension] libraryChanged — library re-scanned")
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
