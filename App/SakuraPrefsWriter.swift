// SakuraPrefsWriter.swift — app-side writer for sakura-prefs.json.
// Adapted from Phosphene/WallpaperPrefsService.swift (write path only).
//
// Converts the app's Screen_Registry (old UserDefaults format) into SakuraPrefs JSON
// and writes it to the extension container. Posts com.sakura.wallpaper.prefsChanged
// so the extension reloads immediately without polling.
//
// Thread safety: all writes go through write(prefs:) which is @MainActor. The app
// should always call from the main actor to match.

import Foundation
import os

private let logger = Logger(subsystem: "com.sakura.wallpaper", category: "prefs")

@MainActor
enum SakuraPrefsWriter {

    // MARK: - Write

    /// Write a SakuraPrefs value to sakura-prefs.json in the extension container,
    /// then post com.sakura.wallpaper.prefsChanged.
    static func write(_ prefs: SakuraPrefs) {
        let url = prefsURL
        do {
            // Create the container Documents directory if the extension hasn't been
            // launched yet (e.g. first app launch before System Settings opens).
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(prefs)
            try data.write(to: url, options: .atomic)
            postPrefsChanged()
            logger.info("Prefs written to \(url.lastPathComponent)")
        } catch {
            logger.error("Failed to write prefs: \(error.localizedDescription)")
        }
    }

    /// Read the current prefs file if it exists, update fields via a closure, then write back.
    /// Use this to update a single field (e.g. userPaused) without clobbering others.
    static func update(_ mutation: (inout SakuraPrefs) -> Void) {
        var prefs = read() ?? SakuraPrefs()
        mutation(&prefs)
        write(prefs)
    }

    /// Read the current sakura-prefs.json, returning nil if it doesn't exist or can't be decoded.
    static func read() -> SakuraPrefs? {
        guard let data = try? Data(contentsOf: prefsURL),
              let prefs = try? JSONDecoder().decode(SakuraPrefs.self, from: data)
        else { return nil }
        return prefs
    }

    // MARK: - UserDefaults migration

    /// Migrate from the old Screen_Registry UserDefaults key to SakuraPrefs JSON.
    ///
    /// If `sakurawallpaper_screen_registry` exists in UserDefaults, convert each entry
    /// to a SakuraDisplayConfig and write sakura-prefs.json. Then delete the old key
    /// so this migration only runs once.
    ///
    /// Call this from the app's init, before any other SakuraPrefsWriter call.
    static func migrateFromLegacyIfNeeded() {
        let legacyKey = "sakurawallpaper_screen_registry"
        guard let data = UserDefaults.standard.data(forKey: legacyKey),
              let registry = try? JSONDecoder().decode(Screen_Registry.self, from: data),
              !registry.isEmpty
        else { return }

        var prefs = read() ?? SakuraPrefs()

        // The legacy Screen_Registry keyed displays as "screen_<directDisplayID>"
        // (see SettingsManager.screenIdentifier). The live app and extension both key
        // per-display config by the bare decimal directDisplayID ("<N>"), so we must
        // strip the "screen_" prefix or every migrated config would be orphaned.
        func normalizeDisplayKey(_ legacyKey: String) -> String {
            legacyKey.hasPrefix("screen_")
                ? String(legacyKey.dropFirst("screen_".count))
                : legacyKey
        }

        for (legacyKey, config) in registry {
            let displayKey = normalizeDisplayKey(legacyKey)
            var displayConfig = SakuraDisplayConfig()
            displayConfig.rotationIntervalMinutes = config.rotationIntervalMinutes
            displayConfig.isRotationEnabled       = config.isRotationEnabled
            displayConfig.isShuffleMode           = config.isShuffleMode
            displayConfig.includeSubfolders        = config.includeSubfolders
            displayConfig.isFolderMode            = config.isFolderMode
            displayConfig.folderPath              = config.folderPath
            // wallpaperPath from the old config is a file URL; the extension library
            // uses UUIDs, so we can't populate entryID here. The user will re-select
            // their video via System Settings after the migration.
            prefs.perDisplayConfig[displayKey] = displayConfig

            // isSynced = true in the old model means the display shares its rotation
            // timer with all other synced displays. Create a single sync group for all.
            // Member displayIDs are normalized to the same bare-number form.
            if config.isSynced && !prefs.syncGroups.contains(where: { $0.groupID == "legacy-sync" }) {
                prefs.syncGroups.append(SakuraSyncGroup(
                    groupID: "legacy-sync",
                    displayIDs: registry.filter { $0.value.isSynced }.map { normalizeDisplayKey($0.key) },
                    rotationIntervalMinutes: config.rotationIntervalMinutes,
                    isShuffleMode: config.isShuffleMode
                ))
            }
        }

        if let policyRaw = UserDefaults.standard.string(forKey: "sakurawallpaper_new_screen_policy") {
            prefs.newScreenPolicy = policyRaw
        }

        write(prefs)
        UserDefaults.standard.removeObject(forKey: legacyKey)
        UserDefaults.standard.removeObject(forKey: "sakurawallpaper_new_screen_policy")
        logger.info("Migrated \(registry.count) display(s) from legacy Screen_Registry")
    }

    // MARK: - Private

    private static var prefsURL: URL {
        MediaDeploymentService.extensionDocsURL
            .appendingPathComponent("sakura-prefs.json")
    }

    private static func postPrefsChanged() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(SakuraNotification.prefsChanged as CFString),
            nil, nil, true
        )
    }
}
