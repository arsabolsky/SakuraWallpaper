// MenuBarView.swift — SwiftUI content for the MenuBarExtra dropdown.
// Ported from AppDelegate.setupStatusBar(), rebuildRecentMenu(), rebuildPauseMenu(), etc.
// Changes: NSMenu/NSMenuItem imperatives → declarative SwiftUI View.
//
// Layout note: MenuBarExtra(.menu) renders its content as a native NSMenu, so
// each Button becomes an NSMenuItem automatically. No custom container needed.

import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var manager: SakuraManager
    @Environment(\.openWindow) var openWindow

    // Language alert state.
    @State private var showLanguageAlert = false
    @State private var pendingLanguage: String?

    var body: some View {
        // Status line — shows what is currently playing or "None".
        if manager.currentVideoName.isEmpty {
            Text("menu.status".localized("ui.notSet".localized))
                .foregroundStyle(.secondary)
        } else {
            Text("menu.status".localized(manager.currentVideoName))
                .foregroundStyle(.secondary)
        }

        Divider()

        // Open the library window.
        Button("menu.open".localized) {
            openWindow(id: "library")
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        // Pause / resume all displays.
        Button(manager.isUserPaused ? "menu.resume".localized : "menu.pause".localized) {
            manager.togglePauseAll()
        }

        // Per-display pause submenu.
        // Each connected NSScreen gets its own pause toggle.
        if NSScreen.screens.count > 1 {
            Menu("menu.pauseScreen".localized) {
                ForEach(NSScreen.screens, id: \.self) { screen in
                    let displayID = screenDisplayID(screen)
                    Button(screenLabel(screen, displayID: displayID)) {
                        if manager.isDisplayPaused(displayID) {
                            manager.resumeDisplay(displayID)
                        } else {
                            manager.pauseDisplay(displayID)
                        }
                    }
                }
            }
        }

        // Advance rotation for all displays without waiting for the timer.
        Button("menu.nextWallpaper".localized) {
            manager.nextWallpaperAllDisplays()
        }
        .disabled(manager.entries.isEmpty)

        // Stop all wallpapers (clears entryID for all displays).
        Button("menu.stopWallpaper".localized) {
            stopAllWallpapers()
        }
        .disabled(manager.entries.isEmpty)

        Divider()

        // Battery Saver: pause desktop wallpaper when on battery.
        // Maps to alwaysPauseDesktop in SakuraPrefs.
        Toggle("menu.autoPause".localized, isOn: Binding(
            get: { manager.prefs.alwaysPauseDesktop },
            set: { newVal in
                manager.prefs.alwaysPauseDesktop = newVal
                manager.savePrefs()
            }
        ))

        Divider()

        // Recent wallpapers (last 5 from history).
        if !manager.prefs.wallpaperHistory.isEmpty {
            Menu("menu.recent".localized) {
                let recent = manager.prefs.wallpaperHistory.prefix(5)
                ForEach(Array(recent), id: \.self) { entryID in
                    if let entry = manager.entries.first(where: { $0.id == entryID }) {
                        Button(entry.name) {
                            applyToFirstDisplay(entryID: entryID)
                        }
                    }
                }
                Divider()
                Button("menu.clearHistory".localized) {
                    manager.prefs.wallpaperHistory = []
                    manager.savePrefs()
                }
            }
        }

        Divider()

        // Language switcher.
        // Changing language requires a restart; we show an alert to explain this.
        Menu("menu.language".localized) {
            languageButton("language.system".localized, code: "system")
            languageButton("language.en".localized, code: "en")
            languageButton("language.zh-Hans".localized, code: "zh-Hans")
        }
        .alert("menu.language".localized, isPresented: $showLanguageAlert, presenting: pendingLanguage) { lang in
            Button("alert.ok".localized) {
                SettingsManager.shared.language = lang
                // A restart is required for the new language bundle to load.
                // We can't hot-swap NSBundle instances at runtime safely.
            }
            Button("alert.cancel".localized, role: .cancel) {}
        } message: { _ in
            Text("language.restartHint".localized)
        }

        Divider()

        Button("menu.about".localized) {
            manager.showAbout = true
        }

        Button("menu.quit".localized) {
            manager.savePrefs()
            NSApp.terminate(nil)
        }
    }

    // MARK: - Helpers

    private func stopAllWallpapers() {
        // Clear the entryID for every display config and save.
        for key in manager.prefs.perDisplayConfig.keys {
            manager.prefs.perDisplayConfig[key]?.entryID = nil
        }
        manager.savePrefs()
    }

    private func applyToFirstDisplay(entryID: String) {
        // Apply to the first connected display's displayID.
        guard let screen = NSScreen.screens.first else { return }
        let displayID = screenDisplayID(screen)
        manager.setWallpaper(entryID: entryID, displayID: displayID)
    }

    /// Build a pause-menu label that shows the display name and current paused state.
    private func screenLabel(_ screen: NSScreen, displayID: String) -> String {
        let name = screen.localizedName
        let paused = manager.isDisplayPaused(displayID)
        let action = paused ? "menu.resume".localized : "menu.pause".localized
        return "\(name) — \(action)"
    }

    /// Extract the decimal directDisplayID string from an NSScreen.
    private func screenDisplayID(_ screen: NSScreen) -> String {
        let raw = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
        return raw.map { "\($0)" } ?? "0"
    }

    @ViewBuilder
    private func languageButton(_ label: String, code: String) -> some View {
        Button {
            pendingLanguage = code
            showLanguageAlert = true
        } label: {
            HStack {
                Text(label)
                if SettingsManager.shared.language == code {
                    Image(systemName: "checkmark")
                }
            }
        }
    }
}
