// swift-tools-version: 5.9
// MARK: - [Phase 0] Updated paths after directory reorganisation.
// Core logic lives in SakuraWallpaperCore/ and is compiled into both the app and the extension.
// Platform bumped to macOS 26 (Tahoe) — the Phosphene architecture requires WallpaperExtensionKit
// which is only available on Tahoe and later.
import PackageDescription

let package = Package(
    name: "SakuraWallpaperCore",
    platforms: [
        // macOS 26 (Tahoe) is required for WallpaperExtensionKit.
        // Using string literal because .v26 isn't in swift-tools-version 5.9's enum yet.
        .macOS("26.0")
    ],
    products: [
        .library(name: "SakuraWallpaperCore", targets: ["SakuraWallpaperCore"])
    ],
    targets: [
        .target(
            name: "SakuraWallpaperCore",
            path: "SakuraWallpaperCore/Sources/SakuraWallpaperCore",
            sources: [
                "Screen_Config.swift",
                "SettingsManager.swift",
                "MediaType.swift",
                "PlaylistBuilder.swift",
                // Phase 3: shared path safety, variant type, and prefs model
                "PathSafety.swift",
                "SakuraVariant.swift",
                "SakuraPrefsModel.swift",
                // Phase 9: moved here so tests can reach it; extension adds SakuraPowerMonitor overload
                "SakuraPlaybackPolicy.swift",
                // Shared Darwin notification names — referenced by both app and extension
                "SakuraNotifications.swift"
            ],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "SakuraWallpaperCoreTests",
            dependencies: ["SakuraWallpaperCore"],
            path: "Tests/SakuraWallpaperCoreTests"
        )
    ]
)
