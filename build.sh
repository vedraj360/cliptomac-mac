#!/bin/bash
set -e

APP_NAME="ClipToMac"
BUNDLE_DIR="$APP_NAME.app"
MACOS_DIR="$BUNDLE_DIR/Contents/MacOS"
RESOURCES_DIR="$BUNDLE_DIR/Contents/Resources"

echo "🔨 Building $APP_NAME..."
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"
cp "Assets/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
if [ -d "Assets/BrandIcons" ]; then
    cp -R "Assets/BrandIcons" "$RESOURCES_DIR/BrandIcons"
fi

swiftc -O -whole-module-optimization \
    -target arm64-apple-macosx13.0 \
    -parse-as-library \
    Sources/*.swift \
    -o "$MACOS_DIR/$APP_NAME"

cat << 'PLIST' > "$BUNDLE_DIR/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ClipToMac</string>
    <key>CFBundleIdentifier</key>
    <string>com.vdx.cliptomac</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleName</key>
    <string>ClipToMac</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "✅ Build complete: $BUNDLE_DIR"
