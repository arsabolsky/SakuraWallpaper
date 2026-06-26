#!/bin/bash
# MARK: - [Phase 0] Updated for new directory layout after Phosphene port reorganisation.
# Source files are now split into three directories:
#   SakuraWallpaperCore/Sources/SakuraWallpaperCore/  — shared logic (app + extension)
#   App/                                               — app-only sources
#   Extension/                                         — extension-only sources (populated Phase 1+)

set -euo pipefail

APP_NAME="SakuraWallpaper"
EXT_NAME="SakuraWallpaperExtension"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
EXT_DIR="$APP_DIR/Contents/PlugIns/$EXT_NAME.appex"
APP_VERSION="2.0.0"
BUNDLE_ID="com.sakura.wallpaper"
EXT_BUNDLE_ID="com.sakura.wallpaper.extension"

# ---------------------------------------------------------------------------
# Core source files — compiled into both the app and (later) the extension.
# ---------------------------------------------------------------------------
CORE_SRCS=(
    SakuraWallpaperCore/Sources/SakuraWallpaperCore/Screen_Config.swift
    SakuraWallpaperCore/Sources/SakuraWallpaperCore/SettingsManager.swift
    SakuraWallpaperCore/Sources/SakuraWallpaperCore/MediaType.swift
    SakuraWallpaperCore/Sources/SakuraWallpaperCore/PlaylistBuilder.swift
    # Phase 3: shared path safety, variant type, and prefs model
    SakuraWallpaperCore/Sources/SakuraWallpaperCore/PathSafety.swift
    SakuraWallpaperCore/Sources/SakuraWallpaperCore/SakuraVariant.swift
    SakuraWallpaperCore/Sources/SakuraWallpaperCore/SakuraPrefsModel.swift
    # Phase 9: playback policy moved to Core so unit tests can reach it
    SakuraWallpaperCore/Sources/SakuraWallpaperCore/SakuraPlaybackPolicy.swift
    # Shared Darwin notification names — used by both app and extension
    SakuraWallpaperCore/Sources/SakuraWallpaperCore/SakuraNotifications.swift
)

# ---------------------------------------------------------------------------
# App source files — menu bar app (non-sandboxed, AppKit for now; SwiftUI in Phase 7).
# ---------------------------------------------------------------------------
APP_SRCS=(
    App/Localization.swift
    # Phase 3: IPC services
    App/SecurityScopedResourceManager.swift
    App/MediaDeploymentService.swift
    App/SakuraPrefsWriter.swift
    # Phase 6: desktop sync
    App/DesktopSyncService.swift
    # Phase 7: SwiftUI app UI (replaces AppKit AppDelegate + MainWindowController)
    # Phase 8: launch-at-login, history wiring, new screen policy
    App/LaunchAtLoginService.swift
    App/SakuraManager.swift
    App/SakuraApp.swift
    App/MenuBarView.swift
    App/LibraryView.swift
    App/RotationControlsView.swift
    App/AboutView.swift
    App/OnboardingView.swift
)

# ---------------------------------------------------------------------------
# Clean
# ---------------------------------------------------------------------------
rm -rf "$BUILD_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/PlugIns"

# ---------------------------------------------------------------------------
# Compile app
# ---------------------------------------------------------------------------
echo "Compiling app..."
swiftc -o "$APP_DIR/Contents/MacOS/$APP_NAME" \
    "${CORE_SRCS[@]}" \
    "${APP_SRCS[@]}" \
    -framework Cocoa -framework SwiftUI -framework AVKit -framework AVFoundation \
    -framework ServiceManagement -framework ImageIO -framework IOKit \
    -framework UniformTypeIdentifiers

# Copy resources and icon
cp -R App/Resources "$APP_DIR/Contents/"
cp App/AppIcon.icns "$APP_DIR/Contents/Resources/"

# Write app Info.plist
cat > "$APP_DIR/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleVersion</key>
    <string>$APP_VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

# ---------------------------------------------------------------------------
# Compile extension (Phase 1: entry point, XPC handler skeleton, state, helpers)
# ---------------------------------------------------------------------------
# The extension uses Objective-C bridging (for CAContext, XPC protocols, audit tokens),
# so it must be compiled with swiftc's -import-objc-header flag pointing at the bridging header.
EXT_SWIFT_SRCS=( $(find Extension -name '*.swift' | sort) )
if [ "${#EXT_SWIFT_SRCS[@]}" -gt 0 ]; then
    echo "Compiling extension (${#EXT_SWIFT_SRCS[@]} Swift files)..."
    mkdir -p "$EXT_DIR/Contents/MacOS"
    mkdir -p "$EXT_DIR/Contents/Resources"

    swiftc -o "$EXT_DIR/Contents/MacOS/$EXT_NAME" \
        -import-objc-header Extension/SakuraWallpaperExtension-Bridging-Header.h \
        "${CORE_SRCS[@]}" \
        "${EXT_SWIFT_SRCS[@]}" \
        -framework Foundation -framework AppKit \
        -framework ExtensionFoundation \
        -framework AVFoundation -framework CoreMedia \
        -framework IOKit -framework IOSurface \
        -framework QuartzCore -framework Security \
        -framework CryptoKit

    # Copy the extension's Info.plist (registers com.apple.wallpaper extension point).
    cp Extension/Info.plist "$EXT_DIR/Contents/"

    # Write the main extension bundle Info.plist (CFBundle* keys + EXAppExtensionAttributes).
    # The EXAppExtensionAttributes dict from Extension/Info.plist is embedded here too
    # so the OS sees both CFBundle metadata and the extension point registration.
    cat > "$EXT_DIR/Contents/Info.plist" << EXTPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$EXT_NAME</string>
    <!-- CFBundlePackageType MUST be "XPC!" for an app extension. Xcode injects this
         automatically; our hand-written plist must set it explicitly or the system
         registers the bundle (pluginkit sees it) but the wallpaper picker will not
         treat it as a loadable extension and it never appears in System Settings. -->
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleIdentifier</key>
    <string>$EXT_BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$EXT_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>SakuraWallpaper</string>
    <key>CFBundleVersion</key>
    <string>$APP_VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <!-- Matches Phosphene's INFOPLIST_KEY_LSUIElement = YES for its extension target. -->
    <key>LSUIElement</key>
    <true/>
    <key>EXAppExtensionAttributes</key>
    <dict>
        <key>EXExtensionPointIdentifier</key>
        <string>com.apple.wallpaper</string>
    </dict>
</dict>
</plist>
EXTPLIST

    # Apply sandbox entitlements to the extension.
    # The extension must run sandboxed; the app does not.
    # Signed FIRST (inside-out): the app signature below seals this .appex,
    # so the extension must already be signed before the app is signed.
    codesign --force --sign - \
        --entitlements Extension/SakuraWallpaperExtension.entitlements \
        "$EXT_DIR"

    echo "Extension built: $EXT_DIR"
fi

# ---------------------------------------------------------------------------
# Sign the whole app bundle LAST (inside-out signing).
# Without this the app is only "linker-signed" (executable only) and the
# embedded .appex is NOT sealed into the app's signature — WallpaperAgent then
# registers the extension but refuses to drive its render lifecycle (acquire()
# never fires). Signing the bundle here seals Contents/PlugIns/*.appex.
# NOTE: ad-hoc (--sign -). A real wallpaper extension on macOS typically needs a
# genuine "Apple Development" identity; ad-hoc may still be rejected for the full
# render lifecycle. If so, build via Xcode with a signed-in Apple ID team instead.
# ---------------------------------------------------------------------------
codesign --force --sign - \
    --entitlements App/SakuraWallpaper.entitlements \
    "$APP_DIR"

echo "Signed app bundle: $APP_DIR"
echo "Verifying bundle signature..."
codesign --verify --strict --verbose=2 "$APP_DIR" 2>&1 | sed 's/^/  /'

echo "Done! App: $APP_DIR"

# ---------------------------------------------------------------------------
# DMG packaging (pass 'dmg' as first argument)
# ---------------------------------------------------------------------------
if [ "${1:-}" = "dmg" ]; then
    echo "Creating DMG..."
    DMG_TMP="dmg_tmp"
    rm -rf "$DMG_TMP" "$APP_NAME.dmg"

    python3 -c "
from PIL import Image
img = Image.open('bg.jpg')
img = img.resize((500, 320), Image.LANCZOS)
img.save('bg.png', optimize=True)
"

    mkdir -p "$DMG_TMP"
    cp -R "$APP_DIR" "$DMG_TMP/"

    create-dmg \
      --volname "$APP_NAME" \
      --volicon "App/AppIcon.icns" \
      --background "bg.png" \
      --window-pos 100 100 \
      --window-size 500 320 \
      --icon-size 80 \
      --icon "$APP_NAME.app" 130 160 \
      --hide-extension "$APP_NAME.app" \
      --app-drop-link 360 160 \
      "$APP_NAME.dmg" \
      "$DMG_TMP" 2>&1 | grep -v "hdiutil does not support"

    rm -f bg.png
    rm -rf "$DMG_TMP"
    echo "Done! DMG: $APP_NAME.dmg"
fi
