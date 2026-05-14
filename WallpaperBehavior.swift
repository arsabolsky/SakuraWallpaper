import Foundation

enum DesktopSyncAction: Equatable {
    case none
    case syncCurrentWallpaper
    case restoreOriginalDesktop
}

enum WallpaperBehavior {
    static func desktopSyncAction(
        wasEnabled: Bool,
        isEnabled: Bool,
        hasOriginalDesktopRecord: Bool
    ) -> DesktopSyncAction {
        if !wasEnabled && isEnabled {
            return .syncCurrentWallpaper
        }

        if wasEnabled && !isEnabled && hasOriginalDesktopRecord {
            return .restoreOriginalDesktop
        }

        return .none
    }

    static func shouldAutoPausePlayback(
        pauseWhenInvisibleEnabled: Bool,
        batteryLevel: Int?,
        isCharging: Bool,
        isDesktopCovered: Bool,
        lowBatteryThreshold: Int = 20
    ) -> Bool {
        guard pauseWhenInvisibleEnabled else { return false }

        if isDesktopCovered {
            return true
        }

        guard let batteryLevel else { return false }
        return !isCharging && batteryLevel <= lowBatteryThreshold
    }
}
