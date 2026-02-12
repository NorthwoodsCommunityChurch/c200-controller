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
    <key>CFBundleName</key>
    <string>C200 Controller</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
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
</dict>
</plist>
EOF

# Ad-hoc code sign
codesign --force --deep --sign - "$APP_BUNDLE"

echo ""
echo "Build complete: $APP_BUNDLE"
echo ""

# Open the app
open "$APP_BUNDLE"
