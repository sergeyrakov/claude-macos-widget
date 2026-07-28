#!/bin/bash
# Build ClaudeUsageBar.swift into a self-contained menu-bar .app bundle.
set -e
cd "$(dirname "$0")"

APP="ClaudeUsageBar.app"
BIN="ClaudeUsageBar"

echo "Compiling…"
swiftc -O ClaudeUsageBar.swift -o "$BIN" -framework AppKit

echo "Packaging $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$BIN" "$APP/Contents/MacOS/$BIN"

# Bundle the read-only usage agent so the app has no hardcoded script path.
cp usage_agent.py "$APP/Contents/Resources/usage_agent.py"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>ClaudeUsageBar</string>
    <key>CFBundleDisplayName</key>     <string>Claude Usage</string>
    <key>CFBundleIdentifier</key>      <string>local.claude.usagebar</string>
    <key>CFBundleVersion</key>         <string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleExecutable</key>      <string>ClaudeUsageBar</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

echo "Done: $(pwd)/$APP"
