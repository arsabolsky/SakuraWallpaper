// SakuraManager.swift — central app state observed by all SwiftUI views.
// Ported from AppDelegate + WallpaperManager orchestration.
// Changes: replaces monolithic WallpaperManager with thin coordinator; actual
//          playback lives in the extension via WallpaperExtensionKit; app-side
//          state is just the prefs + library mirror the user cares about.
//
// Thread safety: @MainActor ensures all mutations happen on the main thread.
// Darwin notification callbacks dispatch back to MainActor explicitly.

import Combine
import Foundation
import os

private let log = Logger(subsystem: "com.sakura.wallpaper", category: "SakuraManager")

@MainActor
final class SakuraManager: ObservableObject {

    // MARK: - Published state

    /// The full prefs model — bindings in views read/write this, then call savePrefs().
    @Published var prefs: SakuraPrefs = SakuraPrefs()

    /// Mirrors the video entries deployed into the extension container.
    /// Rebuilt on every library change notification.
    @Published var entries: [MediaDeploymentService.EntryInfo] = []

    /// True while the user has manually paused all displays.
    @Published var isUserPaused: Bool = false

    /// Name of the video currently playing (derived from stateChanged notifications).
    @Published var currentVideoName: String = ""

    /// Whether the first-run onboarding sheet should be shown.
    @Published var showOnboarding: Bool = false

    /// Whether the About view is presented.
    @Published var showAbout: Bool = false

    // MARK: - Darwin observer token (kept alive to prevent deregistration)

    // Written once on the main thread before concurrent access — nonisolated(unsafe) is safe.
    nonisolated(unsafe) private var isObservingDarwin = false

    // MARK: - Init

    init() {
        // Load the persisted prefs immediately so the UI can read them before
        // startServices() is called. startServices() triggers migration which
        // may rewrite prefs, so we read first, migrate later.
        reloadPrefs()
        isUserPaused = prefs.userPaused
    }

    // MARK: - Service startup

    /// Call once at app launch (from SakuraAppDelegate.applicationDidFinishLaunching).
    func startServices() {
        // Migrate old sakurawallpaper_screen_registry UserDefaults → sakura-prefs.json.
        // This is idempotent; the migration deletes its source key on completion.
        SakuraPrefsWriter.migrateFromLegacyIfNeeded()

        // Re-read prefs after migration in case the migration wrote new values.
        reloadPrefs()
        isUserPaused = prefs.userPaused

        // Start the desktop sync service that applies JPEG snapshots via NSWorkspace.
        DesktopSyncService.shared.startObserving()

        // Mirror the extension library into the app's published entries list.
        loadEntries()

        // Watch for library and state changes from the extension.
        observeDarwinNotifications()

        // Show onboarding on first launch (no entries + no prefs history).
        if entries.isEmpty && prefs.wallpaperHistory.isEmpty {
            showOnboarding = true
        }

        log.info("SakuraManager services started — \(self.entries.count) entries, onboarding: \(self.showOnboarding)")
    }

    // MARK: - Library management

    /// Refresh the published entries list from the extension container.
    func loadEntries() {
        entries = MediaDeploymentService.listEntries()
        log.debug("Loaded \(self.entries.count) entries from extension container")
    }

    /// Import a video file from the user's filesystem into the extension container.
    /// Kicks off an async Task so the caller doesn't have to be async.
    func importVideo(url: URL) {
        Task {
            let name = url.deletingPathExtension().lastPathComponent
            await MediaDeploymentService.deployVideo(url: url, name: name)
            // Reload the list on the main actor after deployment completes.
            await MainActor.run { self.loadEntries() }
        }
    }

    /// Remove an entry from the extension container and refresh the list.
    func removeEntry(id: String) {
        MediaDeploymentService.removeVideo(entryID: id)
        loadEntries()
    }

    // MARK: - Wallpaper selection

    /// Assign a video entry as the wallpaper for a specific display and save.
    /// Also records the choice in the wallpaperHistory (capped at 10).
    func setWallpaper(entryID: String, displayID: String) {
        // Update the per-display config.
        var config = prefs.perDisplayConfig[displayID] ?? SakuraDisplayConfig()
        config.entryID = entryID
        prefs.perDisplayConfig[displayID] = config

        // Append to history (newest first, max 10).
        var history = prefs.wallpaperHistory.filter { $0 != entryID }
        history.insert(entryID, at: 0)
        if history.count > 10 { history = Array(history.prefix(10)) }
        prefs.wallpaperHistory = history

        savePrefs()
        updateCurrentVideoName(entryID: entryID)
        log.info("Set wallpaper for display \(displayID): \(entryID.suffix(8))")
    }

    // MARK: - Pause / resume

    /// Toggle the global user-paused flag and persist.
    func togglePauseAll() {
        isUserPaused.toggle()
        prefs.userPaused = isUserPaused
        savePrefs()
        log.info("Paused all: \(self.isUserPaused)")
    }

    func pauseDisplay(_ displayID: String) {
        var set = prefs.pausedDisplays ?? []
        guard let did = UInt32(displayID) else { return }
        set.insert(did)
        prefs.pausedDisplays = set
        savePrefs()
    }

    func resumeDisplay(_ displayID: String) {
        guard let did = UInt32(displayID) else { return }
        prefs.pausedDisplays?.remove(did)
        savePrefs()
    }

    func isDisplayPaused(_ displayID: String) -> Bool {
        guard let did = UInt32(displayID) else { return false }
        return prefs.pausedDisplays?.contains(did) ?? false
    }

    // MARK: - Launch at login

    var isLaunchAtLoginEnabled: Bool {
        LaunchAtLoginService.isEnabled
    }

    func toggleLaunchAtLogin() {
        LaunchAtLoginService.toggle()
        // Force the UI to re-read the new state.
        objectWillChange.send()
    }

    // MARK: - Next wallpaper

    /// Advance rotation for all displays immediately.
    /// Posts a prefsChanged Darwin notification — the extension's RotationEngine
    /// re-reads prefs, but the actual "next" is driven by the extension's actor.
    func nextWallpaperAllDisplays() {
        postDarwinNotification(SakuraNotification.prefsChanged)
    }

    // MARK: - Prefs persistence

    /// Write the current prefs to disk and notify the extension.
    func savePrefs() {
        SakuraPrefsWriter.write(prefs)
    }

    // MARK: - Private helpers

    private func reloadPrefs() {
        // SakuraPrefsWriter reads from the extension container Documents dir.
        // The extension writes sakura-prefs.json there; the app mirrors it.
        guard let data = try? Data(contentsOf: prefsFileURL()) else { return }
        if let decoded = try? JSONDecoder().decode(SakuraPrefs.self, from: data) {
            prefs = decoded
        }
    }

    private func prefsFileURL() -> URL {
        // Same path that SakuraPrefsWriter reads/writes.
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.sakura.wallpaper.extension")
            .appendingPathComponent("Data/Documents")
        return container.appendingPathComponent("sakura-prefs.json")
    }

    private func updateCurrentVideoName(entryID: String) {
        currentVideoName = entries.first { $0.id == entryID }?.name ?? entryID
    }

    private func postDarwinNotification(_ name: String) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(name as CFString),
            nil, nil, true
        )
    }

    // MARK: - Darwin notification observer

    /// Register for stateChanged and libraryChanged notifications from the extension.
    /// Called once from startServices(). The callback dispatches to MainActor.
    private func observeDarwinNotifications() {
        guard !isObservingDarwin else { return }
        isObservingDarwin = true

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()

        // stateChanged: extension advanced to a new video.
        CFNotificationCenterAddObserver(
            center, observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let mgr = Unmanaged<SakuraManager>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in mgr.handleStateChanged() }
            },
            SakuraNotification.stateChanged as CFString,
            nil, .deliverImmediately
        )

        // libraryChanged: app deployed a new video into the container.
        CFNotificationCenterAddObserver(
            center, observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let mgr = Unmanaged<SakuraManager>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in mgr.loadEntries() }
            },
            SakuraNotification.libraryChanged as CFString,
            nil, .deliverImmediately
        )

        log.info("Observing Darwin: stateChanged + libraryChanged")
    }

    private func handleStateChanged() {
        // Re-read current prefs to discover which entry is now active.
        reloadPrefs()
        // Refresh the video name shown in the menu bar status line.
        if let firstDisplay = prefs.perDisplayConfig.first?.value,
           let entryID = firstDisplay.entryID {
            updateCurrentVideoName(entryID: entryID)
        }
    }
}
