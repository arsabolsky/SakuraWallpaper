// SakuraExtensionState.swift — thread-safe shared state for the extension process.
// Adapted from PhospheneExtension/WallpaperState.swift.
// Changes from Phosphene original:
//   - Renamed to SakuraExtensionState / SakuraContext
//   - renderer typed as SakuraRenderer? (was AnyObject? in Phase 1 placeholder)
//   - Darwin notification name uses SakuraNotification.libraryChanged
//   - Removed WallpaperPrefs.shared.setActive call (Phase 3)

import Foundation
import os
import QuartzCore

// MARK: - SakuraContext

/// One active rendering context: the remote CAContext, its root layer, and
/// the renderer driving it. One context = one display × one wallpaper session.
struct SakuraContext: @unchecked Sendable {
    /// Private CAContext held as AnyObject — its contextId routes frames to WindowServer.
    let caContext: AnyObject
    let rootLayer: CALayer
    /// The active video renderer for this context.
    /// nil during the brief window between acquire() and the first start() call.
    let renderer: SakuraRenderer?
    /// DirectDisplayID for this context, used to route per-display policy updates.
    let displayID: UInt32?
    /// The video UUID chosen for this context (from choiceConfiguration in acquire).
    /// Each context keeps its own choice so multi-monitor setups don't race.
    let videoID: String?
}

// MARK: - SakuraExtensionState

/// Singleton holding all live rendering contexts and presentation/lock state.
/// All mutations are protected by OSAllocatedUnfairLock.
final class SakuraExtensionState: Sendable {
    static let shared = SakuraExtensionState()

    private static let selectedVideoKey = "sakura.selectedVideoID"

    private struct State: @unchecked Sendable {
        /// contextId (UInt32 from CAContext) → SakuraContext
        var activeContexts: [UInt32: SakuraContext] = [:]
        /// wallpaperID UUID string → contextId, for targeted invalidation
        var wallpaperIDToContext: [String: UInt32] = [:]
        var cachedThumbnailURL: URL?
        var cacheDirectoryURL: URL?
        /// Last user-selected video UUID, persisted to UserDefaults so the menu-bar
        /// UI has a sensible default before the user picks anything after a relaunch.
        var currentVideoID: String? = UserDefaults.standard.string(forKey: SakuraExtensionState.selectedVideoKey)
        var presentationMode: String = "active"
        var activityState: String = "active"
        var isDisplayAsleep: Bool = false
        var isScreenLocked: Bool = false
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    private init() {
        // Clear cached snapshot URLs when the library changes so the next lookup
        // re-evaluates against the freshly-scanned video set.
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let state = Unmanaged<SakuraExtensionState>.fromOpaque(observer).takeUnretainedValue()
                state.clearCaches()
            },
            SakuraNotification.libraryChanged as CFString,
            nil,
            .deliverImmediately
        )
    }

    private func clearCaches() {
        lock.withLock { $0.cachedThumbnailURL = nil }
    }

    // MARK: - Context Management

    /// Store a new rendering context. If wallpaperID already has a context, the old
    /// one is returned so the caller can stop its renderer before discarding it.
    func storeContext(_ context: SakuraContext, id: UInt32, wallpaperID: String?) -> SakuraContext? {
        lock.withLock { state in
            var existing: SakuraContext?
            if let wid = wallpaperID, let oldId = state.wallpaperIDToContext[wid] {
                existing = state.activeContexts.removeValue(forKey: oldId)
            }
            state.activeContexts[id] = context
            if let wid = wallpaperID { state.wallpaperIDToContext[wid] = id }
            return existing
        }
    }

    /// Remove and return the context for a wallpaperID UUID string (called from invalidate).
    func removeContext(wallpaperID: String) -> SakuraContext? {
        lock.withLock { state in
            guard let contextId = state.wallpaperIDToContext.removeValue(forKey: wallpaperID) else { return nil }
            return state.activeContexts.removeValue(forKey: contextId)
        }
    }

    /// Remove all contexts and stop their renderers.
    func removeAllContexts() {
        let all: [SakuraContext] = lock.withLock { state in
            let all = Array(state.activeContexts.values)
            state.activeContexts.removeAll()
            state.wallpaperIDToContext.removeAll()
            return all
        }
        // Stop renderers outside the lock — renderer.stop() dispatches to the
        // renderer queue and must not hold the state lock while doing so.
        for ctx in all { ctx.renderer?.stop() }
    }

    /// Call a closure on every active renderer. Extracts renderers under the lock,
    /// releases the lock, then calls the closure — safe against re-entrancy.
    func forEachRenderer(_ body: (SakuraRenderer) -> Void) {
        let renderers: [SakuraRenderer] = lock.withLock { state in
            state.activeContexts.values.compactMap { $0.renderer }
        }
        for renderer in renderers { body(renderer) }
    }

    var activeContextCount: Int {
        lock.withLock { $0.activeContexts.count }
    }

    // MARK: - Properties

    var cachedThumbnailURL: URL? {
        get { lock.withLock { $0.cachedThumbnailURL } }
        set { lock.withLock { $0.cachedThumbnailURL = newValue } }
    }

    var cacheDirectoryURL: URL? {
        get { lock.withLock { $0.cacheDirectoryURL } }
        set { lock.withLock { $0.cacheDirectoryURL = newValue } }
    }

    var currentVideoID: String? {
        get { lock.withLock { $0.currentVideoID } }
        set {
            lock.withLock { $0.currentVideoID = newValue }
            UserDefaults.standard.set(newValue, forKey: SakuraExtensionState.selectedVideoKey)
        }
    }

    var presentationMode: String {
        get { lock.withLock { $0.presentationMode } }
        set { lock.withLock { $0.presentationMode = newValue } }
    }

    var activityState: String {
        get { lock.withLock { $0.activityState } }
        set { lock.withLock { $0.activityState = newValue } }
    }

    var isDisplayAsleep: Bool {
        get { lock.withLock { $0.isDisplayAsleep } }
        set { lock.withLock { $0.isDisplayAsleep = newValue } }
    }

    var isScreenLocked: Bool {
        get { lock.withLock { $0.isScreenLocked } }
        set { lock.withLock { $0.isScreenLocked = newValue } }
    }
}
