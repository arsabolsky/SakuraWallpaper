// RotationEngine.swift — per-display and sync-group video rotation.
// SakuraWallpaper feature: implements the folder rotation, shuffle, per-display timers,
// and sync groups that distinguish SakuraWallpaper from Phosphene.
//
// Design:
//   Each display or sync group gets one Swift concurrency Task that sleeps for the
//   configured interval, then advances the playlist. The Task loop re-reads the
//   rotation interval from SakuraPrefsProvider on every iteration so the user's
//   changes in the settings UI take effect on the next cycle without restarting the Task.
//
//   SakuraExtensionState holds SakuraContext (with SakuraRenderer). RotationEngine
//   does NOT hold renderer references directly — it calls into SakuraExtensionState to
//   reach the renderer for a display. This avoids retain cycles and keeps the state
//   single-source-of-truth in SakuraExtensionState.
//
//   Phase 5 will wire acquire() to call startRotation(displayID:) and
//   selectedChoicesDidChange to call setExplicitMedia(displayID:entryID:).

import Foundation
import os

// MARK: - RotationEngine

actor RotationEngine {
    static let shared = RotationEngine()

    // MARK: - Private state

    /// Per-display rotation state (keyed by display UUID string from SakuraPrefs).
    private var displayStates: [String: DisplayState] = [:]
    /// Running Task handles for per-display timers. Cancelling removes the loop.
    private var displayTasks: [String: Task<Void, Never>] = [:]
    /// Running Task handles for sync-group timers. One Task drives all group members.
    private var groupTasks: [String: Task<Void, Never>] = [:]
    /// Per-group playlist and current index (managed here, NOT in SakuraPrefs).
    private var groupState: [String: GroupState] = [:]

    // MARK: - Per-display rotation

    /// Start (or restart) an independent rotation timer for a display.
    ///
    /// Cancels any previous timer for this display. If the config has rotation
    /// disabled or interval == 0, stores state but does not start a Task.
    func startRotation(displayID: String, config: SakuraDisplayConfig) {
        stopDisplayTask(displayID)

        let playlist = buildPlaylist(for: config)
        let entry = config.entryID ?? playlist.first
        displayStates[displayID] = DisplayState(
            currentEntryID: entry,
            playlist: playlist,
            currentIndex: playlist.firstIndex(of: entry ?? "") ?? 0,
            isSuspended: false,
            config: config
        )

        guard config.isRotationEnabled, config.rotationIntervalMinutes > 0 else {
            extensionLog("[RotationEngine] Display \(displayID.suffix(8)): rotation disabled")
            return
        }

        let task = Task.detached { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                // Re-read the interval each iteration so a settings change takes effect
                // on the next cycle without cancelling and restarting this Task.
                let minutes = await self.intervalMinutes(for: displayID)
                guard minutes > 0 else {
                    // Interval was set to 0 (manual only) — check again in 30s.
                    try? await Task.sleep(for: .seconds(30))
                    continue
                }

                try? await Task.sleep(for: .seconds(Double(minutes) * 60))
                guard !Task.isCancelled else { return }

                let suspended = await self.isSuspended(displayID: displayID)
                if !suspended {
                    await self.advanceDisplay(displayID: displayID)
                }
            }
        }
        displayTasks[displayID] = task
        extensionLog("[RotationEngine] Display \(displayID.suffix(8)): rotation started (\(config.rotationIntervalMinutes) min, shuffle: \(config.isShuffleMode))")
    }

    /// Start (or restart) a sync-group rotation timer.
    ///
    /// All displays in the group advance to the same playlist index simultaneously.
    /// The group's playlist is built from the union of all member displays' playlists.
    func startSyncGroup(_ group: SakuraSyncGroup) {
        stopGroupTask(group.groupID)

        let playlist = buildGroupPlaylist(for: group)
        groupState[group.groupID] = GroupState(playlist: playlist, currentIndex: 0)

        guard group.rotationIntervalMinutes > 0 else { return }

        let groupID = group.groupID
        let task = Task.detached { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let minutes = await self.groupIntervalMinutes(for: groupID)
                guard minutes > 0 else {
                    try? await Task.sleep(for: .seconds(30))
                    continue
                }
                try? await Task.sleep(for: .seconds(Double(minutes) * 60))
                guard !Task.isCancelled else { return }
                await self.advanceSyncGroup(groupID: groupID)
            }
        }
        groupTasks[groupID] = task
        extensionLog("[RotationEngine] SyncGroup \(groupID.suffix(8)): started (\(group.rotationIntervalMinutes) min)")
    }

    // MARK: - Manual control

    /// Advance a display to the next entry immediately (user pressed "Next").
    func advanceDisplay(displayID: String) {
        guard var state = displayStates[displayID] else { return }
        guard !state.playlist.isEmpty else { return }
        state.currentIndex = PlaylistBuilder.nextIndex(
            currentIndex: state.currentIndex,
            itemCount: state.playlist.count,
            shuffle: state.config.isShuffleMode
        )
        state.currentEntryID = state.playlist[state.currentIndex]
        displayStates[displayID] = state
        applyEntry(state.currentEntryID, toDisplay: displayID)
        extensionLog("[RotationEngine] Display \(displayID.suffix(8)): → entry \(state.currentEntryID?.suffix(8) ?? "nil")")
    }

    func advanceSyncGroup(groupID: String) {
        guard var gs = groupState[groupID] else { return }
        guard !gs.playlist.isEmpty else { return }

        // Find which displays are in this group.
        let prefs = SakuraPrefsProvider.shared.current
        let groupConfig = prefs.syncGroups.first { $0.groupID == groupID }
        guard let displayIDs = groupConfig?.displayIDs, !displayIDs.isEmpty else { return }

        let shuffle = groupConfig?.isShuffleMode ?? false
        gs.currentIndex = PlaylistBuilder.nextIndex(
            currentIndex: gs.currentIndex,
            itemCount: gs.playlist.count,
            shuffle: shuffle
        )
        let entryID = gs.playlist[gs.currentIndex]
        groupState[groupID] = gs

        // Apply the SAME entry to all displays in the group simultaneously.
        for displayID in displayIDs {
            if var state = displayStates[displayID] {
                state.currentEntryID = entryID
                displayStates[displayID] = state
            }
            applyEntry(entryID, toDisplay: displayID)
        }
        extensionLog("[RotationEngine] SyncGroup \(groupID.suffix(8)): → entry \(entryID.suffix(8)) (all \(displayIDs.count) display(s))")
    }

    /// Called from SakuraXPCHandler.selectedChoicesDidChange when the user picks a
    /// video from System Settings — overrides the rotation playlist's current position.
    func setExplicitMedia(displayID: String, entryID: String) {
        if var state = displayStates[displayID] {
            // Update the playlist position to the explicitly-chosen entry so the NEXT
            // rotation advance continues from this point rather than jumping back.
            if let idx = state.playlist.firstIndex(of: entryID) {
                state.currentIndex = idx
            }
            state.currentEntryID = entryID
            displayStates[displayID] = state
        } else {
            // Display not yet started (no prefs-driven rotation) — create minimal state.
            displayStates[displayID] = DisplayState(
                currentEntryID: entryID,
                playlist: [entryID],
                currentIndex: 0,
                isSuspended: false,
                config: SakuraDisplayConfig()
            )
        }
        applyEntry(entryID, toDisplay: displayID)
        extensionLog("[RotationEngine] Display \(displayID.suffix(8)): explicit → \(entryID.suffix(8))")
    }

    // MARK: - Suspend / resume

    /// Pause rotation advances for a display (policy is .paused). The timer Task
    /// keeps sleeping — it just skips the advance when it wakes.
    func suspend(displayID: String) {
        if var state = displayStates[displayID] {
            state.isSuspended = true
            displayStates[displayID] = state
        }
    }

    func resume(displayID: String) {
        if var state = displayStates[displayID] {
            state.isSuspended = false
            displayStates[displayID] = state
        }
    }

    // MARK: - Teardown

    func stopRotation(displayID: String) {
        stopDisplayTask(displayID)
        displayStates.removeValue(forKey: displayID)
    }

    func stopSyncGroup(groupID: String) {
        stopGroupTask(groupID)
        groupState.removeValue(forKey: groupID)
    }

    func stopAll() {
        for (id, task) in displayTasks { task.cancel(); displayTasks.removeValue(forKey: id) }
        for (id, task) in groupTasks   { task.cancel(); groupTasks.removeValue(forKey: id) }
        displayStates.removeAll()
        groupState.removeAll()
    }

    // MARK: - Query

    /// The entry UUID currently assigned to a display. Used by the snapshot handler.
    func currentEntryID(for displayID: String) -> String? {
        displayStates[displayID]?.currentEntryID
    }

    // MARK: - Private helpers

    private struct DisplayState {
        var currentEntryID: String?
        var playlist: [String]     // [entryID]
        var currentIndex: Int
        var isSuspended: Bool
        var config: SakuraDisplayConfig
    }

    private struct GroupState {
        var playlist: [String]
        var currentIndex: Int
    }

    private func stopDisplayTask(_ displayID: String) {
        displayTasks[displayID]?.cancel()
        displayTasks.removeValue(forKey: displayID)
    }

    private func stopGroupTask(_ groupID: String) {
        groupTasks[groupID]?.cancel()
        groupTasks.removeValue(forKey: groupID)
    }

    /// Re-read the rotation interval for a display from the live prefs.
    /// Called each loop iteration so interval changes take effect naturally.
    private func intervalMinutes(for displayID: String) -> Int {
        SakuraPrefsProvider.shared.current.perDisplayConfig[displayID]?.rotationIntervalMinutes
            ?? displayStates[displayID]?.config.rotationIntervalMinutes
            ?? 15
    }

    private func groupIntervalMinutes(for groupID: String) -> Int {
        SakuraPrefsProvider.shared.current.syncGroups
            .first { $0.groupID == groupID }?.rotationIntervalMinutes ?? 15
    }

    private func isSuspended(displayID: String) -> Bool {
        displayStates[displayID]?.isSuspended ?? false
    }

    /// Build a playlist of entry UUIDs for a display config.
    ///
    /// In folder mode: uses all library entries (approximate — the app should have
    /// deployed the folder's videos into the container; Phase 7 will add per-folder
    /// tagging to filter more precisely).
    /// In single-entry mode: playlist is just [entryID] (no rotation unless enabled).
    private func buildPlaylist(for config: SakuraDisplayConfig) -> [String] {
        let all = SakuraLibrary.shared.entries.map { $0.id }
        guard !all.isEmpty else { return config.entryID.map { [$0] } ?? [] }

        if config.isFolderMode {
            // Folder mode: rotate through all deployed videos.
            // Phase 7 will filter by folder path tag on each entry.
            return all
        }

        if let entryID = config.entryID, all.contains(entryID) {
            // Single-entry + rotation enabled: rotate through all entries but start here.
            if config.isRotationEnabled {
                // Put the chosen entry first so the starting position is predictable.
                var ordered = all.filter { $0 != entryID }
                ordered.insert(entryID, at: 0)
                return ordered
            }
            return [entryID]
        }

        // No selection yet — use all entries.
        return all
    }

    private func buildGroupPlaylist(for group: SakuraSyncGroup) -> [String] {
        // Group playlist = union of all member displays' playlists.
        let all = SakuraLibrary.shared.entries.map { $0.id }
        return all
    }

    /// Apply an entry change to a display. In Phase 5 this will actually update the
    /// renderer's variantSelector and trigger a media switch. For now it records the
    /// selection in SakuraExtensionState.currentVideoID and posts a Darwin notification
    /// so the app-side HistoryMenuSection can see the change.
    private func applyEntry(_ entryID: String?, toDisplay displayID: String) {
        guard let entryID else { return }

        // Update the global "current video" so snapshot and settings can read it.
        SakuraExtensionState.shared.currentVideoID = entryID

        // TODO(Phase 5): look up the SakuraContext for this displayID via SakuraExtensionState,
        //   get its renderer, and call:
        //     renderer.variantSelector = { [weak lib = SakuraLibrary.shared] in
        //         lib?.bestVariantURL(for: entryID, policy: SakuraPlaybackPolicy.current) ?? url
        //     }
        //   Then, if the current video is different, stop the renderer and restart it with
        //   the new URL so the switch happens at the next loop boundary.

        // Notify the app that the displayed video changed.
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(SakuraNotification.stateChanged as CFString),
            nil, nil, true
        )
    }
}
