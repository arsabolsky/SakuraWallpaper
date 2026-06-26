// SakuraApp.swift — SwiftUI entry point for SakuraWallpaper.
// Replaces AppDelegate.swift + main.swift.
// Ported from AppDelegate.applicationDidFinishLaunching setup.
//
// MenuBarExtra provides the status-bar icon and dropdown menu.
// A separate Window declaration lets the user open the library panel via
// "Open SakuraWallpaper" in the menu bar dropdown.
//
// SakuraAppDelegate is an NSApplicationDelegate that calls manager.startServices()
// at launch — needed because SwiftUI's @State initialisation happens before the
// first scene render, but Darwin observers should start after the app is fully up.

import ServiceManagement
import SwiftUI

// MARK: - @main

@main
struct SakuraApp: App {
    // The delegate starts services and holds the manager reference so the NSApp
    // lifecycle hooks can reach it without a global singleton.
    @NSApplicationDelegateAdaptor(SakuraAppDelegate.self) var appDelegate

    var body: some Scene {
        // Status-bar icon + dropdown menu.
        // style: .menu means the icon acts as a normal menu bar item that shows a
        // SwiftUI view when clicked — matching the original NSMenu behaviour.
        MenuBarExtra("SakuraWallpaper", image: "MenuBarIcon") {
            MenuBarView()
                .environmentObject(appDelegate.manager)
        }
        .menuBarExtraStyle(.menu)

        // Library window — opened from "Open SakuraWallpaper" in the menu bar.
        // id: "library" lets MenuBarView call openWindow(id: "library").
        Window("SakuraWallpaper", id: "library") {
            LibraryView()
                .environmentObject(appDelegate.manager)
                .frame(minWidth: 640, minHeight: 480)
        }
        .defaultSize(width: 800, height: 560)

        // Settings / About lives inside MenuBarView as a sheet.
    }
}

// MARK: - App delegate

/// Minimal NSApplicationDelegate. Holds the manager so both the @main App struct
/// and any future AppKit callbacks can reach it without a global.
final class SakuraAppDelegate: NSObject, NSApplicationDelegate {
    // manager is created here (not in App.body) so it is alive before any scene renders.
    let manager = SakuraManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start IPC services, migrate legacy prefs, hook Darwin notifications.
        manager.startServices()

        // Prevent the app from appearing in the Dock — it's menu-bar only.
        // LSUIElement = true in Info.plist handles this at startup; this call
        // handles the edge case where LSUIElement was not set before launch.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running when the library window is closed — the menu bar icon stays.
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Flush any pending prefs writes before the process exits.
        manager.savePrefs()
    }
}
