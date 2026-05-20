import Foundation
import ServiceManagement
import Cocoa

public enum AppearanceMode: String, Codable, CaseIterable {
    case system
    case light
    case dark
}

public struct OriginalDesktopRecord: Codable, Equatable {
    public var imagePath: String
    public var imageScalingRawValue: Int?
    public var allowClipping: Bool?
    public var fillColorData: Data?

    public init(imagePath: String, imageScalingRawValue: Int?, allowClipping: Bool?, fillColorData: Data?) {
        self.imagePath = imagePath
        self.imageScalingRawValue = imageScalingRawValue
        self.allowClipping = allowClipping
        self.fillColorData = fillColorData
    }

    init(imageURL: URL, desktopOptions: [NSWorkspace.DesktopImageOptionKey: Any]) {
        self.imagePath = imageURL.path
        if let scaling = desktopOptions[.imageScaling] as? NSNumber {
            imageScalingRawValue = scaling.intValue
        } else {
            imageScalingRawValue = nil
        }
        if let clipping = desktopOptions[.allowClipping] as? NSNumber {
            allowClipping = clipping.boolValue
        } else if let clipping = desktopOptions[.allowClipping] as? Bool {
            allowClipping = clipping
        } else {
            allowClipping = nil
        }
        if let fillColor = desktopOptions[.fillColor] as? NSColor {
            fillColorData = try? NSKeyedArchiver.archivedData(withRootObject: fillColor, requiringSecureCoding: true)
        } else {
            fillColorData = nil
        }
    }

    var imageURL: URL {
        URL(fileURLWithPath: imagePath)
    }

    var desktopImageOptions: [NSWorkspace.DesktopImageOptionKey: Any] {
        var options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
        if let imageScalingRawValue {
            options[.imageScaling] = NSNumber(value: imageScalingRawValue)
        }
        if let allowClipping {
            options[.allowClipping] = NSNumber(value: allowClipping)
        }
        if let fillColorData,
           let fillColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: fillColorData) {
            options[.fillColor] = fillColor
        }
        return options
    }
}

public class SettingsManager {
    public static let shared = SettingsManager()

    private let defaults: UserDefaults

    // MARK: - UserDefaults Keys (retained)
    private let launchKey                = "sakurawallpaper_launch_at_login"
    private let pauseWhenInvisibleKey    = "sakurawallpaper_pause_when_invisible"
    private let historyKey               = "sakurawallpaper_history"
    private let languageKey              = "sakurawallpaper_language"
    private let onboardingCompletedKey   = "sakurawallpaper_onboarding_completed"
    private let syncDesktopWallpaperKey  = "sakurawallpaper_sync_desktop_wallpaper"

    // MARK: - UserDefaults Keys (new)
    private let screenRegistryKey        = "sakurawallpaper_screen_registry"
    private let newScreenPolicyKey       = "sakurawallpaper_new_screen_policy"
    private let appearanceModeKey        = "sakurawallpaper_appearance_mode"
    private let originalDesktopRecordsKey = "sakurawallpaper_original_desktop_records"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Screen Registry API

    public func screenConfig(for screenID: String) -> Screen_Config {
        guard let data = defaults.data(forKey: screenRegistryKey) else {
            return Screen_Config.default
        }
        do {
            let registry = try JSONDecoder().decode(Screen_Registry.self, from: data)
            return registry[screenID] ?? Screen_Config.default
        } catch {
            print("SettingsManager: failed to decode screen registry: \(error)")
            return Screen_Config.default
        }
    }

    public func setScreenConfig(_ config: Screen_Config, for screenID: String) {
        var registry: Screen_Registry
        if let data = defaults.data(forKey: screenRegistryKey),
           let decoded = try? JSONDecoder().decode(Screen_Registry.self, from: data) {
            registry = decoded
        } else {
            registry = [:]
        }
        registry[screenID] = config
        if let data = try? JSONEncoder().encode(registry) {
            defaults.set(data, forKey: screenRegistryKey)
        }
    }

    // MARK: - Original Desktop Records

    func originalDesktopRecord(for screenID: String) -> OriginalDesktopRecord? {
        originalDesktopRegistry()[screenID]
    }

    func setOriginalDesktopRecord(_ record: OriginalDesktopRecord, for screenID: String) {
        var registry = originalDesktopRegistry()
        registry[screenID] = record
        saveOriginalDesktopRegistry(registry)
    }

    func removeOriginalDesktopRecord(for screenID: String) {
        var registry = originalDesktopRegistry()
        registry.removeValue(forKey: screenID)
        if registry.isEmpty {
            defaults.removeObject(forKey: originalDesktopRecordsKey)
        } else {
            saveOriginalDesktopRegistry(registry)
        }
    }

    // MARK: - New Screen Policy

    var newScreenPolicy: New_Screen_Policy {
        get {
            guard let raw = defaults.string(forKey: newScreenPolicyKey),
                  let policy = New_Screen_Policy(rawValue: raw) else {
                return .inheritSyncGroup
            }
            return policy
        }
        set {
            defaults.set(newValue.rawValue, forKey: newScreenPolicyKey)
        }
    }

    var appearanceMode: AppearanceMode {
        get {
            guard let raw = defaults.string(forKey: appearanceModeKey),
                  let mode = AppearanceMode(rawValue: raw) else {
                return .system
            }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: appearanceModeKey)
        }
    }

    // MARK: - Clean-Slate Init

    func runCleanSlateInitIfNeeded() {
        // Guard: if registry already exists, do nothing
        guard defaults.object(forKey: screenRegistryKey) == nil else { return }

        // Delete all legacy keys
        let legacyKeys = [
            "sakurawallpaper_folder_path",
            "sakurawallpaper_wallpaper_path",
            "sakurawallpaper_screen_folder_configs",
            "sakurawallpaper_screen_wallpapers",
            "sakurawallpaper_is_folder_mode",
            "sakurawallpaper_rotation_interval_minutes",
            "sakurawallpaper_is_shuffle_mode",
            "sakurawallpaper_is_rotation_enabled",
            "sakurawallpaper_include_subfolders",
            "sakurawallpaper_new_screen_inheritance_mode",
            "sakurawallpaper_new_screen_inheritance_screen_id"
        ]
        for key in legacyKeys {
            defaults.removeObject(forKey: key)
        }

        // Initialize empty registry
        let emptyRegistry: Screen_Registry = [:]
        if let data = try? JSONEncoder().encode(emptyRegistry) {
            defaults.set(data, forKey: screenRegistryKey)
        }
    }

    // MARK: - Retained Properties

    var onboardingCompleted: Bool {
        get { defaults.bool(forKey: onboardingCompletedKey) }
        set { defaults.set(newValue, forKey: onboardingCompletedKey) }
    }

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: launchKey) }
        set {
            defaults.set(newValue, forKey: launchKey)
            updateLoginItem(enabled: newValue)
        }
    }

    var pauseWhenInvisible: Bool {
        get { defaults.bool(forKey: pauseWhenInvisibleKey) }
        set { defaults.set(newValue, forKey: pauseWhenInvisibleKey) }
    }

    var syncDesktopWallpaper: Bool {
        get {
            if defaults.object(forKey: syncDesktopWallpaperKey) == nil { return true }
            return defaults.bool(forKey: syncDesktopWallpaperKey)
        }
        set { defaults.set(newValue, forKey: syncDesktopWallpaperKey) }
    }

    var wallpaperHistory: [String] {
        get { defaults.stringArray(forKey: historyKey) ?? [] }
        set { defaults.set(newValue, forKey: historyKey) }
    }

    var language: String {
        get { defaults.string(forKey: languageKey) ?? "system" }
        set { defaults.set(newValue, forKey: languageKey) }
    }

    // MARK: - Screen Identifier

    public static func screenIdentifier(_ screen: NSScreen) -> String {
        return screenIdentifier(deviceDescription: screen.deviceDescription, name: screen.localizedName)
    }

    /// Testable core of screenIdentifier. Accepts raw device description and name
    /// so tests can exercise the logic without instantiating NSScreen.
    static func screenIdentifier(deviceDescription: [NSDeviceDescriptionKey: Any], name: String) -> String {
        if let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return "screen_\(number.uint32Value)"
        }
        // Deterministic fallback derived from stable screen properties (Bug 3 fix).
        // Uses localizedName + frame dimensions so the same physical screen always
        // maps to the same identifier, even when NSScreenNumber is temporarily unavailable.
        let sizeValue = deviceDescription[NSDeviceDescriptionKey("NSDeviceSize")] as? NSValue
        let size = sizeValue?.sizeValue ?? .zero
        let w = Int(size.width)
        let h = Int(size.height)
        return "screen_fallback_\(name)_\(w)x\(h)"
    }

    // MARK: - Private Helpers

    func addToHistory(_ path: String) {
        var history = wallpaperHistory.filter { $0 != path }
        history.insert(path, at: 0)
        if history.count > 10 { history = Array(history.prefix(10)) }
        wallpaperHistory = history
    }

    private func updateLoginItem(enabled: Bool) {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            do {
                if enabled { try service.register() } else { try service.unregister() }
            } catch {
                print("Failed to update login item: \(error)")
            }
        }
    }

    private func originalDesktopRegistry() -> [String: OriginalDesktopRecord] {
        guard let data = defaults.data(forKey: originalDesktopRecordsKey) else {
            return [:]
        }
        do {
            return try JSONDecoder().decode([String: OriginalDesktopRecord].self, from: data)
        } catch {
            print("SettingsManager: failed to decode original desktop records: \(error)")
            return [:]
        }
    }

    private func saveOriginalDesktopRegistry(_ registry: [String: OriginalDesktopRecord]) {
        if let data = try? JSONEncoder().encode(registry) {
            defaults.set(data, forKey: originalDesktopRecordsKey)
        }
    }
}
