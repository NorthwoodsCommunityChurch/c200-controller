#!/bin/bash
set -e

APP_NAME="C200Controller"
BUILD_DIR="$(pwd)/.build/release"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"

echo "Building $APP_NAME..."

# Build release
swift build -c release

# Create app bundle structure
rm -rf "$APP_BUNDLE"
mkdir -p "$CONTENTS/MacOS"
mkdir -p "$CONTENTS/Resources"

# Copy executable
cp "$BUILD_DIR/$APP_NAME" "$CONTENTS/MacOS/"

# Copy app icon
ICON_SOURCE="$(dirname "$0")/../icons/AppIcon.icns"
if [ -f "$ICON_SOURCE" ]; then
    cp "$ICON_SOURCE" "$CONTENTS/Resources/AppIcon.icns"
    echo "App icon installed."
else
    echo "Warning: AppIcon.icns not found at $ICON_SOURCE"
fi

# Create Info.plist
cat > "$CONTENTS/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>C200Controller</string>
    <key>CFBundleIdentifier</key>
    <string>org.northwoodschurch.C200Controller</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleName</key>
    <string>C200 Controller</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.11</string>
    <key>CFBundleVersion</key>
    <string>10</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>C200 Controller needs local network access to communicate with the ESP32 bridge and discover devices via Bonjour.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_http._tcp</string>
    </array>
    <key>SUPublicEDKey</key>
    <string>VIMxKZmmRokdMcHK5d3QU4+qHgBglmkVFP5aAVvxgqM=</string>
    <key>SUFeedURL</key>
    <string>https://northwoodscommunitychurch.github.io/app-updates/appcast-c200controller.xml</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
</dict>
</plist>
EOF

# Bundle Sparkle framework (SPM doesn't do this automatically)
SPARKLE_FRAMEWORK="$BUILD_DIR/Sparkle.framework"
xattr -cr "$SPARKLE_FRAMEWORK"
mkdir -p "$CONTENTS/Frameworks"
cp -R "$SPARKLE_FRAMEWORK" "$CONTENTS/Frameworks/"
xattr -cr "$CONTENTS/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$CONTENTS/MacOS/$APP_NAME"
echo "Sparkle framework bundled."

# Bundle ESP32 firmware binary + version
FIRMWARE_SOURCE="$(dirname "$0")/../ESP32Flasher/FirmwareTemplate/build/c200_bridge.bin"
MAIN_C="$(dirname "$0")/../ESP32Flasher/FirmwareTemplate/main/main.c"
if [ -f "$FIRMWARE_SOURCE" ]; then
    cp "$FIRMWARE_SOURCE" "$CONTENTS/Resources/c200_bridge.bin"
    FW_VERSION=$(grep '#define FIRMWARE_VERSION' "$MAIN_C" | sed 's/.*"\(.*\)".*/\1/')
    [ -n "$FW_VERSION" ] && echo "$FW_VERSION" > "$CONTENTS/Resources/firmware_version.txt"
    echo "Firmware ${FW_VERSION:-unknown} bundled."
else
    echo "Warning: c200_bridge.bin not found — OTA will require manual firmware selection."
fi

# Sign Sparkle nested components inside-out, then sign the whole app
xattr -cr "$APP_BUNDLE"
codesign --force --sign - "$CONTENTS/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc"
codesign --force --sign - "$CONTENTS/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"
codesign --force --sign - "$CONTENTS/Frameworks/Sparkle.framework/Versions/B/Updater.app"
codesign --force --sign - "$CONTENTS/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
codesign --force --sign - "$CONTENTS/Frameworks/Sparkle.framework"
codesign --force --deep --sign - "$APP_BUNDLE"

echo ""
echo "Build complete: $APP_BUNDLE"
echo ""

# Open the app
open "$APP_BUNDLE"
