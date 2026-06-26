// LaunchAtLoginService.swift — SMAppService wrapper for launch-at-login.
// Ported from Phosphene/LaunchAtLoginService.swift.
// Changes: none; SMAppService is the same API on macOS 13+.
//
// SMAppService replaces the old LoginItems (LSSharedFileList) and helper-bundle
// approaches. No helper app is needed; the main app registers itself directly.
// The registration is stored in ~/Library/LaunchAgents by the system.

import Foundation
import ServiceManagement
import os

private let log = Logger(subsystem: "com.sakura.wallpaper", category: "LaunchAtLogin")

@MainActor
enum LaunchAtLoginService {
    // MARK: - State

    /// True when the app is registered to launch at login.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    // MARK: - Enable / Disable

    /// Register the app to launch at login. No-ops if already registered.
    static func enable() {
        guard !isEnabled else { return }
        do {
            try SMAppService.mainApp.register()
            log.info("Launch at login enabled")
        } catch {
            log.error("Failed to enable launch at login: \(error)")
        }
    }

    /// Unregister the app from launching at login.
    static func disable() {
        guard isEnabled else { return }
        do {
            try SMAppService.mainApp.unregister()
            log.info("Launch at login disabled")
        } catch {
            log.error("Failed to disable launch at login: \(error)")
        }
    }

    /// Toggle registration.
    static func toggle() {
        if isEnabled { disable() } else { enable() }
    }
}
