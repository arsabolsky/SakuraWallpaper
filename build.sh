#!/bin/bash

APP_NAME="SakuraWallpaper"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"

# 清理
rm -rf "$BUILD_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# 编译
echo "Compiling..."
swiftc -o "$APP_DIR/Contents/MacOS/$APP_NAME" \
    SettingsManager.swift \
    MediaType.swift \
    Localization.swift \
    ScreenPlayer.swift \
    WallpaperManager.swift \
    MainWindowController.swift \
    AboutWindowController.swift \
    AppDelegate.swift \
    main.swift \
    -framework Cocoa -framework AVKit -framework AVFoundation -framework ServiceManagement

# 复制资源
cp -R Resources "$APP_DIR/Contents/"

# 复制图标
cp AppIcon.icns "$APP_DIR/Contents/Resources/"

# 创建 Info.plist
cat > "$APP_DIR/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.sakura.wallpaper</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleVersion</key>
    <string>0.1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

echo "Done! App: $APP_DIR"

# 打包 DMG（传入 dmg 参数）
if [ "$1" = "dmg" ]; then
    echo "Creating DMG..."
    DMG_TMP="dmg_tmp"
    rm -rf "$DMG_TMP" "$APP_NAME.dmg"

    # 生成背景图（箭头 + 提示文字）
    python3 << PYEOF
from PIL import Image, ImageDraw, ImageFont
img = Image.new("RGBA", (500, 320), (240, 240, 240, 255))
draw = ImageDraw.Draw(img)
draw.line([(200, 160), (300, 160)], fill=(120, 120, 120), width=3)
draw.polygon([(300, 150), (315, 160), (300, 170)], fill=(120, 120, 120))
try:
    font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 16)
except:
    font = ImageFont.load_default()
draw.text((170, 180), "拖拽到此处安装", fill=(140, 140, 140), font=font)
img.save("bg.png")
PYEOF

    # 准备内容
    mkdir -p "$DMG_TMP"
    cp -R "$APP_DIR" "$DMG_TMP/"

    # 用 create-dmg 打包（需 brew install create-dmg）
    create-dmg \
      --volname "$APP_NAME" \
      --volicon "AppIcon.icns" \
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
