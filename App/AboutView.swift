// AboutView.swift — app info sheet.
// Ported from AboutWindowController.swift.
// Changes: NSWindow → SwiftUI sheet presented from LibraryView.

import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) var dismiss

    // Read version from the bundle — the swiftc-built binary embeds Info.plist.
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        VStack(spacing: 16) {
            // App icon from asset catalog.
            if let img = NSImage(named: "AppIcon") {
                Image(nsImage: img)
                    .resizable()
                    .frame(width: 80, height: 80)
            }

            Text("about.title".localized)
                .font(.title2.bold())

            Text("about.version".localized(version))
                .foregroundStyle(.secondary)

            Text("about.description".localized)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)

            Divider()

            // Supported formats section.
            VStack(alignment: .leading, spacing: 4) {
                Text("about.formatsTitle".localized)
                    .font(.headline)
                Text("MP4 · MOV · M4V")
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text("ui.madeBy".localized("♥"))
                .foregroundStyle(.tertiary)
                .font(.caption)

            Button("alert.ok".localized) { dismiss() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .padding(24)
        .frame(minWidth: 320)
    }
}
