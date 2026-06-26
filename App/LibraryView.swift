// LibraryView.swift — main library window with video grid + per-display rotation controls.
// Ported from MainWindowController.swift.
// Changes: AppKit NSCollectionView + NSWindow → SwiftUI LazyVGrid + Window.
//
// Layout:
//   ┌─────────────────────────────────────────────────────┐
//   │  [Display picker tabs]        [Import Video...]      │
//   │  ┌──┐ ┌──┐ ┌──┐ ┌──┐                               │
//   │  │  │ │  │ │  │ │  │   (thumbnail grid)             │
//   │  └──┘ └──┘ └──┘ └──┘                               │
//   │  ── Rotation Controls ──────────────────────────     │
//   │  [Enable Rotation] [Shuffle] [Interval: 15 mins]    │
//   └─────────────────────────────────────────────────────┘

import AppKit
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var manager: SakuraManager

    // The display currently shown in the grid / for which the controls apply.
    @State private var selectedDisplayID: String = ""

    // Controls whether the onboarding sheet is shown on first launch.
    @State private var showOnboarding: Bool = false

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            // ── Display picker ───────────────────────────────────────────────
            // One tab per connected NSScreen. Selecting a tab changes which
            // display the grid is configuring.
            if NSScreen.screens.count > 1 {
                Picker("", selection: $selectedDisplayID) {
                    ForEach(NSScreen.screens, id: \.self) { screen in
                        Text(screen.localizedName)
                            .tag(screenDisplayID(screen))
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 12)
            }

            // ── Video grid ──────────────────────────────────────────────────
            ScrollView {
                if manager.entries.isEmpty {
                    // Empty state — guide the user to import a video.
                    VStack(spacing: 16) {
                        Image(systemName: "film.stack")
                            .font(.system(size: 48))
                            .foregroundStyle(.tertiary)
                        Text("ui.dropHere".localized)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text("ui.formats".localized)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 60)
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(manager.entries, id: \.id) { entry in
                            EntryCard(
                                entry: entry,
                                isSelected: manager.prefs.perDisplayConfig[selectedDisplayID]?.entryID == entry.id
                            )
                            .onTapGesture {
                                manager.setWallpaper(entryID: entry.id, displayID: selectedDisplayID)
                            }
                            .contextMenu {
                                Button("ui.stopWallpaper".localized, role: .destructive) {
                                    manager.removeEntry(id: entry.id)
                                }
                            }
                        }
                    }
                    .padding(12)
                }
            }
            // Accept video file drops anywhere on the grid.
            .dropDestination(for: URL.self) { urls, _ in
                for url in urls where isVideoURL(url) {
                    manager.importVideo(url: url)
                }
                return true
            }

            Divider()

            // ── Rotation controls ───────────────────────────────────────────
            RotationControlsView(displayID: selectedDisplayID)
                .environmentObject(manager)
                .padding(12)
        }
        .navigationTitle("SakuraWallpaper")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("ui.selectFile".localized) { importVideo() }
            }
        }
        // Set the initial selected display to the primary display.
        .onAppear {
            if selectedDisplayID.isEmpty, let first = NSScreen.screens.first {
                selectedDisplayID = screenDisplayID(first)
            }
            // Show onboarding on very first launch.
            if manager.entries.isEmpty && manager.prefs.wallpaperHistory.isEmpty {
                showOnboarding = true
            }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView()
                .environmentObject(manager)
        }
        .sheet(isPresented: $manager.showAbout) {
            AboutView()
        }
    }

    // MARK: - Helpers

    /// Open a file picker for video files and import the selection.
    private func importVideo() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = videoContentTypes()
        panel.message = "ui.selectFile".localized
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where isVideoURL(url) {
            manager.importVideo(url: url)
        }
    }

    private func screenDisplayID(_ screen: NSScreen) -> String {
        let raw = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
        return raw.map { "\($0)" } ?? "0"
    }

    private func isVideoURL(_ url: URL) -> Bool {
        ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased())
    }

    private func videoContentTypes() -> [UTType] {
        // UniformTypeIdentifiers is available macOS 11+; macOS 26 definitely has it.
        [.mpeg4Movie, .quickTimeMovie]
    }
}

// MARK: - EntryCard

/// One cell in the video grid: thumbnail image + name label.
private struct EntryCard: View {
    let entry: MediaDeploymentService.EntryInfo
    let isSelected: Bool

    // Path to the thumbnail image inside the extension container.
    private var thumbnailURL: URL? {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.sakura.wallpaper.extension")
            .appendingPathComponent("Data/Documents/videos/\(entry.id)/thumbnail.jpg")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                if let url = thumbnailURL, let img = NSImage(contentsOf: url) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(16/9, contentMode: .fill)
                } else {
                    // No thumbnail yet — show a placeholder.
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .aspectRatio(16/9, contentMode: .fit)
                        .overlay(Image(systemName: "film").foregroundStyle(.tertiary))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                // Selection ring.
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2.5)
            )

            Text(entry.name)
                .lineLimit(2)
                .font(.caption)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - UTType import

import UniformTypeIdentifiers
