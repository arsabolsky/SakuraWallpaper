// SakuraPlaybackPolicy.swift — graduated playback policy for the extension.
// Adapted from PhospheneExtension/PlaybackPolicy.swift.
// Changes: PlaybackPolicy → SakuraPlaybackPolicy, PowerMonitor → SakuraPowerMonitor.
//
// The policy is a pure function of observable system state — no side effects —
// so it is easy to unit-test and reason about. Call `compute(...)` whenever any
// input changes; apply the result to all active SakuraRenderer instances.

import Foundation

/// Central decision-maker for video playback behaviour.
/// Replaces scattered shouldPause booleans with a tiered policy that lets the
/// renderer reduce work gradually rather than switching abruptly.
enum SakuraPlaybackPolicy: Int, Sendable, Comparable {
    /// Render at full resolution and full frame rate.
    case full    = 0
    /// Reduce frame rate (used on battery to save power).
    case reduced = 1
    /// Minimum viable frame rate (used with low battery or serious thermals).
    case minimal = 2
    /// Stop advancing the timebase (used when the user pauses, display is off, or thermals are critical).
    case paused  = 3

    static func < (lhs: SakuraPlaybackPolicy, rhs: SakuraPlaybackPolicy) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    // MARK: - Policy computation

    /// Evaluate all conditions and return the most restrictive applicable policy.
    ///
    /// This is the primary overload — all inputs are explicit, making the function
    /// deterministic and fully unit-testable without mocking system state.
    ///
    /// `alwaysPauseDesktop`: when true, the wallpaper only plays on the lock screen.
    /// Lock screen never reduces FPS on its own — only power/thermal conditions do.
    static func compute(
        presentationMode: String,    // "active" | "locked" | "idle"
        activityState: String,       // "active" | "suspended"
        userPaused: Bool,
        alwaysPauseDesktop: Bool,
        pauseWhenOccluded: Bool,
        desktopOccluded: Bool,
        thermalState: ProcessInfo.ThermalState,
        isOnBattery: Bool,
        batteryLevel: Int,           // 0–100
        isGameModeActive: Bool,
        displayBrightness: Float = 1.0  // 0.0–1.0
    ) -> SakuraPlaybackPolicy {
        var worst: SakuraPlaybackPolicy = .full

        // --- paused tier ---
        // Any one of these conditions forces a full stop.
        if userPaused { worst = max(worst, .paused) }
        if thermalState == .critical { worst = max(worst, .paused) }
        if batteryLevel < 10 { worst = max(worst, .paused) }
        // "suspended" means the process may sleep; don't burn CPU on a dormant renderer.
        if activityState.contains("suspended") { worst = max(worst, .paused) }
        // "idle" means no display activity (e.g. screen saver); nothing is visible.
        if presentationMode == "idle" { worst = max(worst, .paused) }
        if isGameModeActive { worst = max(worst, .paused) }
        // User dimmed the backlight to near-zero. The display is technically awake
        // so screensDidSleep doesn't fire and the WallpaperAgent never sets "idle",
        // but the content is invisible — pausing saves battery.
        if displayBrightness < SakuraPowerMonitor.PowerState.brightnessPauseThreshold {
            worst = max(worst, .paused)
        }
        // Desktop occlusion (Mission Control, full-screen apps) is irrelevant on the
        // lock screen — the wallpaper is always fully visible there.
        if pauseWhenOccluded, desktopOccluded, presentationMode != "locked" { worst = max(worst, .paused) }
        if alwaysPauseDesktop, presentationMode != "locked" { worst = max(worst, .paused) }

        // --- minimal tier ---
        if thermalState == .serious { worst = max(worst, .minimal) }
        // SakuraWallpaper feature: auto-pause below 20% battery (mirrors the original
        // WallpaperManager.shouldPauseForLowBattery threshold).
        if isOnBattery, batteryLevel < 20 { worst = max(worst, .minimal) }

        // --- reduced tier ---
        if thermalState == .fair { worst = max(worst, .reduced) }
        // On any battery power, reduce FPS to extend runtime.
        if isOnBattery { worst = max(worst, .reduced) }

        return worst
    }

    /// Convenience overload that unpacks a `SakuraPowerMonitor.PowerState`.
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

    // MARK: - FPS tier generation

    /// Generate FPS tiers by repeated halving from a source frame rate.
    /// Tiers are used by SakuraLibrary to select the appropriate video variant
    /// for the current policy level.
    ///
    /// Keeps halving until the result is at or below 15 fps. Always produces ≥2 tiers.
    /// Examples: 120 → [120, 60, 30, 15], 60 → [60, 30, 15], 30 → [30, 15], 24 → [24, 12].
    static func fpsTiers(from sourceFPS: Int) -> [Int] {
        guard sourceFPS > 0 else { return [] }
        var tiers = [sourceFPS]
        var current = sourceFPS
        while current > 15 {
            current /= 2
            tiers.append(current)
        }
        if tiers.count < 2 {
            tiers.append(current / 2)
        }
        return tiers
    }
}
