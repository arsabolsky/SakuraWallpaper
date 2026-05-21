// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SakuraWallpaperCore",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .library(name: "SakuraWallpaperCore", targets: ["SakuraWallpaperCore"]),
        .executable(name: "sakura-mcp", targets: ["sakura-mcp"])
    ],
    targets: [
        .target(
            name: "SakuraWallpaperCore",
            path: ".",
            exclude: [
                "Resources",
                "img",
                "build",
                "docs",
                "Tests",
                "AppDelegate.swift",
                "MainWindowController.swift",
                "MCPGUIControlServer.swift",
                "AboutWindowController.swift",
                "main.swift",
                "AppIcon.icns",
                "bg.jpg",
                "README.md",
                "README_CN.md",
                "LICENSE",
                "build.sh",
                "reset.sh",
                "SakuraWallpaper.dmg",
                "SakuraWallpaper.entitlements",
                "Sources"
            ],
            sources: [
                "Screen_Config.swift",
                "SettingsManager.swift",
                "WallpaperBehavior.swift",
                "MCPControlTypes.swift",
                "MediaType.swift",
                "PlaylistBuilder.swift",
                "AsyncWorkLimiter.swift",
                "Localization.swift",
                "PerformanceMonitor.swift",
                "ScreenPlayer.swift",
                "WallpaperManager.swift",
                "ThumbnailItem.swift",
                "ThumbnailProvider.swift"
            ],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("AVKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("ImageIO"),
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "sakura-mcp",
            dependencies: ["SakuraWallpaperCore"],
            path: "Sources/sakura-mcp"
        ),
        .testTarget(
            name: "SakuraWallpaperCoreTests",
            dependencies: ["SakuraWallpaperCore"],
            path: "Tests/SakuraWallpaperCoreTests"
        ),
        .testTarget(
            name: "sakura-mcpTests",
            dependencies: ["sakura-mcp"],
            path: "Tests/sakura-mcpTests"
        )
    ]
)
