#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="GeminiQuotaBar"
APP_BUNDLE="$ROOT_DIR/$APP_NAME.app"
CACHE_DIR="/tmp/gemini-quota-bar-module-cache"

echo "Building $APP_NAME (release)..."
mkdir -p "$CACHE_DIR"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

swiftc \
    -O \
    -parse-as-library \
    -module-cache-path "$CACHE_DIR" \
    -framework AppKit \
    -framework Foundation \
    "$ROOT_DIR/Sources/GeminiQuotaBar/QuotaModels.swift" \
    "$ROOT_DIR/Sources/GeminiQuotaBar/QuotaService.swift" \
    "$ROOT_DIR/Sources/GeminiQuotaBar/ChatGPTQuotaService.swift" \
    "$ROOT_DIR/Sources/GeminiQuotaBar/MenuBarRenderer.swift" \
    "$ROOT_DIR/Sources/GeminiQuotaBar/AppDelegate.swift" \
    "$ROOT_DIR/Sources/GeminiQuotaBar/main.swift" \
    -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

cat > "$APP_BUNDLE/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>GeminiQuotaBar</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.GeminiQuotaBar</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>GeminiQuotaBar</string>
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
EOF

echo "Done! App bundle created at: $APP_BUNDLE"
