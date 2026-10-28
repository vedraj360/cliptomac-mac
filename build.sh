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
    ditto "Assets/BrandIcons" "$RESOURCES_DIR/BrandIcons"
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
    <key>NSLocalNetworkUsageDescription</key>
    <string>Securely transfer clips and files with your paired phone on your local network.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "✅ Build complete: $BUNDLE_DIR"

# Certificate signing is opt-in. Set this only after the developer authorizes that identity.
# The ignored local identity file is written only after explicit developer approval.
if [ "${CLIPTOMAC_SIGN_IDENTITY+x}" = x ]; then
    APP_SIGN_IDENTITY="$CLIPTOMAC_SIGN_IDENTITY"
elif [ -f .local-signing-identity ]; then
    APP_SIGN_IDENTITY="$(cat .local-signing-identity)"
else
    APP_SIGN_IDENTITY=""
fi
if [ -n "$APP_SIGN_IDENTITY" ]; then
    codesign --force --options runtime --identifier com.vdx.cliptomac --sign "$APP_SIGN_IDENTITY" "$BUNDLE_DIR"
    codesign --verify --strict "$BUNDLE_DIR"
    echo "Explicitly requested certificate signing applied."
else
    codesign --force --identifier com.vdx.cliptomac --sign - "$BUNDLE_DIR"
    echo "Local ad-hoc build. Certificate signing requires explicit CLIPTOMAC_SIGN_IDENTITY opt-in."
fi
