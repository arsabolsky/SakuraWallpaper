// OnboardingView.swift — 3-step first-run setup.
// Ported from MainWindowController's onboarding path.
// Changes: NSTabView wizard → SwiftUI sheet with step state.
//
// Steps:
//   0 — Pick a wallpaper video (file picker)
//   1 — Set the rotation interval (optional)
//   2 — Enable launch at login (optional)

import ServiceManagement
import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var manager: SakuraManager
    @Environment(\.dismiss) var dismiss

    @State private var step = 0
    @State private var pickedFileName = ""
    @State private var intervalMinutes = 15
    @State private var launchAtLoginEnabled = false

    var body: some View {
        VStack(spacing: 24) {
            // Progress indicator.
            HStack(spacing: 8) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(i <= step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }

            // ── Step content ────────────────────────────────────────────────
            Group {
                switch step {
                case 0: stepPickWallpaper
                case 1: stepSetInterval
                case 2: stepLaunchAtLogin
                default: EmptyView()
                }
            }
            .frame(minHeight: 140)

            Divider()

            // Navigation buttons.
            HStack {
                Button("onboarding.skip".localized) {
                    dismiss()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)

                Spacer()

                if step < 2 {
                    Button("Next") {
                        withAnimation { step += 1 }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Done") {
                        applyLaunchAtLogin()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(28)
        .frame(minWidth: 380)
    }

    // MARK: - Step views

    private var stepPickWallpaper: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)
            Text("onboarding.step1.title".localized)
                .font(.title3.bold())
            Text("onboarding.step1.message".localized)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button("onboarding.pickFile".localized) {
                    pickVideo()
                }
                .buttonStyle(.bordered)
            }

            if !pickedFileName.isEmpty {
                Text(pickedFileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var stepSetInterval: some View {
        VStack(spacing: 16) {
            Image(systemName: "timer")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)
            Text("onboarding.step2.title".localized)
                .font(.title3.bold())
            Text("onboarding.step2.message".localized)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Quick presets.
            HStack(spacing: 10) {
                ForEach([5, 15, 30], id: \.self) { mins in
                    Button("\(mins) \("ui.minutes".localized)") {
                        intervalMinutes = mins
                        applyInterval()
                    }
                    // Can't ternary two concrete ButtonStyle types — use one style
                    // and signal selection via tint instead.
                    .buttonStyle(.bordered)
                    .tint(intervalMinutes == mins ? Color.accentColor : nil)
                }
            }

            // Fine-grained stepper.
            Stepper(
                value: $intervalMinutes, in: 1...180,
                label: { Text("\("ui.rotationInterval".localized): \(intervalMinutes) \("ui.minutes".localized)") }
            )
            .frame(maxWidth: 260)
            .onChange(of: intervalMinutes) { _, _ in applyInterval() }
        }
    }

    private var stepLaunchAtLogin: some View {
        VStack(spacing: 16) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)
            Text("onboarding.step3.title".localized)
                .font(.title3.bold())
            Text("onboarding.step3.message".localized)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Toggle("ui.launchAtLogin".localized, isOn: $launchAtLoginEnabled)
                .toggleStyle(.switch)
        }
    }

    // MARK: - Helpers

    private func pickVideo() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pickedFileName = url.lastPathComponent
        manager.importVideo(url: url)
        // Advance to the next step automatically after picking.
        withAnimation { step = 1 }
    }

    private func applyInterval() {
        // Apply the chosen interval to all currently-configured displays.
        for key in manager.prefs.perDisplayConfig.keys {
            manager.prefs.perDisplayConfig[key]?.rotationIntervalMinutes = intervalMinutes
        }
        manager.savePrefs()
    }

    private func applyLaunchAtLogin() {
        guard launchAtLoginEnabled else { return }
        // SMAppService replaces the old LoginItems approach on macOS 13+.
        do {
            try SMAppService.mainApp.register()
        } catch {
            // Non-fatal: the user can enable this later from System Settings.
        }
    }
}

// UTType import is already in LibraryView.swift, but each file must be self-contained.
import UniformTypeIdentifiers
