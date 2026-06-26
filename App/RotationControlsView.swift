// RotationControlsView.swift — per-display rotation settings strip.
// Ported from MainWindowController.swift rotation controls section.
// Changes: NSStackView + NSButton → SwiftUI Form.
//
// Shows rotation settings for the currently-selected display. Writes changes
// immediately to SakuraPrefs via manager.savePrefs() so the extension picks
// them up on the next prefsChanged Darwin notification.

import SwiftUI

struct RotationControlsView: View {
    @EnvironmentObject var manager: SakuraManager

    /// The display this view configures (decimal directDisplayID string).
    let displayID: String

    // Computed binding to the per-display config. Returns a default config if
    // this display hasn't been configured yet — on first write, the default is
    // inserted into prefs.perDisplayConfig.
    private var config: Binding<SakuraDisplayConfig> {
        Binding(
            get: {
                manager.prefs.perDisplayConfig[displayID] ?? SakuraDisplayConfig()
            },
            set: { newConfig in
                manager.prefs.perDisplayConfig[displayID] = newConfig
                manager.savePrefs()
            }
        )
    }

    var body: some View {
        // Using HStack instead of Form to match the original toolbar-style strip
        // at the bottom of the window. A Form would add too much vertical padding.
        HStack(spacing: 20) {
            // Enable / disable automatic rotation for this display.
            Toggle("ui.enableRotation".localized, isOn: config.isRotationEnabled)
                .toggleStyle(.checkbox)

            // Interval stepper (1–180 minutes). Only interactive when rotation is enabled.
            if config.isRotationEnabled.wrappedValue {
                Stepper(value: config.rotationIntervalMinutes, in: 1...180) {
                    Text("\("ui.rotationInterval".localized): \(config.rotationIntervalMinutes.wrappedValue) \("ui.minutes".localized)")
                }
                .frame(maxWidth: 200)

                // Shuffle: randomise playlist order instead of sequential.
                Toggle("ui.shuffleMode".localized, isOn: config.isShuffleMode)
                    .toggleStyle(.checkbox)

                // Folder mode: rotate through all deployed videos rather than a
                // single chosen entry. Overrides the per-display entryID selection.
                Toggle("ui.folderMode".localized, isOn: config.isFolderMode)
                    .toggleStyle(.checkbox)
            }

            Spacer()
        }
        .font(.system(size: 12))
        .disabled(displayID.isEmpty)
    }
}
