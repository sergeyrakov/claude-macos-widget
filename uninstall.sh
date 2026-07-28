#!/bin/bash
# Remove ClaudeUsageBar: stop it, unregister the LaunchAgent, delete the app and
# the local cache. Does NOT touch your Claude Code login (it never owned it).
set -e

LABEL="local.claude.usagebar"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
INSTALL_PATH="$HOME/Applications/ClaudeUsageBar.app"

echo "==> Unloading LaunchAgent"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"

echo "==> Quitting app"
pkill -x ClaudeUsageBar 2>/dev/null || true

echo "==> Removing installed app"
rm -rf "$INSTALL_PATH"

echo "==> Removing local cache"
rm -rf "$HOME/.config/claude-usage-widget"

echo "Done. Your Claude Code login was not touched."
