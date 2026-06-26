// SakuraPlaybackPolicy.swift — extension-only convenience overload.
// The SakuraPlaybackPolicy enum and its core compute() function live in
// SakuraWallpaperCore/SakuraPlaybackPolicy.swift (compiled via CORE_SRCS).
// This file adds the overload that unpacks a SakuraPowerMonitor.PowerState,
// which references SakuraPowerMonitor — an extension-only type.

import Foundation

extension SakuraPlaybackPolicy {
    /// Convenience overload that unpacks a SakuraPowerMonitor.PowerState.
    /// Used in the policy-recompute loop in SakuraWallpaperExtension.
    static func compute(
        presentationMode: String,
        activityState: String,
        userPaused: Bool,
        alwaysPauseDesktop: Bool,
        pauseWhenOccluded: Bool,
        desktopOccluded: Bool,
        powerState: SakuraPowerMonitor.PowerState
    ) -> SakuraPlaybackPolicy {
        compute(
            presentationMode: presentationMode,
            activityState: activityState,
            userPaused: userPaused,
            alwaysPauseDesktop: alwaysPauseDesktop,
            pauseWhenOccluded: pauseWhenOccluded,
            desktopOccluded: desktopOccluded,
            thermalState: powerState.thermalState,
            isOnBattery: powerState.isOnBattery,
            batteryLevel: powerState.batteryLevel,
            isGameModeActive: powerState.isGameModeActive,
            displayBrightness: powerState.displayBrightness
        )
    }
}
