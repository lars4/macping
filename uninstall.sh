#!/bin/bash
# Removes the macping LaunchAgent and all its files.
set -u

LABEL="com.macping.agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
rm -rf "$HOME/.macping"
rm -f /tmp/macping-loc.txt

echo "macping removed."
echo "If you granted location access, you can also remove 'MacPingLoc' under"
echo "System Settings > Privacy & Security > Location Services."
