#!/bin/bash
# Build ClaudeUsageBar, install it to ~/Applications, and register a LaunchAgent
# so it starts at login. Safe to re-run (idempotent).
set -e
cd "$(dirname "$0")"

APP_NAME="ClaudeUsageBar.app"
INSTALL_DIR="$HOME/Applications"
INSTALL_PATH="$INSTALL_DIR/$APP_NAME"
LABEL="local.claude.usagebar"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "==> Building"
bash build.sh

echo "==> Installing to $INSTALL_PATH"
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_PATH"
cp -R "$APP_NAME" "$INSTALL_PATH"

echo "==> Writing LaunchAgent $PLIST"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>-a</string>
        <string>$INSTALL_PATH</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
PLISTEOF

echo "==> Loading LaunchAgent (also launches it now)"
UID_NUM=$(id -u)
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST"

echo
echo "Installed. Look for the widget in the top-right menu bar."
echo "If it shows '✦ login', run  claude  then  /login  in a Terminal once."
