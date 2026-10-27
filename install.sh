#!/bin/bash
# Installs macping as a per-user LaunchAgent. Run WITHOUT sudo:  bash install.sh
set -euo pipefail

LABEL="com.macping.agent"
DIR="$HOME/.macping"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SRC="$(cd "$(dirname "$0")" && pwd)"

[ "$(uname)" = "Darwin" ] || { echo "macping only runs on macOS." >&2; exit 1; }
[ "$(id -u)" -ne 0 ]      || { echo "Please run without sudo." >&2; exit 1; }

mkdir -p "$DIR" "$HOME/Library/LaunchAgents"
install -m 755 "$SRC/macping.sh" "$DIR/macping.sh"

# ---- Config -----------------------------------------------------------------
if [ ! -f "$DIR/config" ]; then
  echo "Create a bot with @BotFather in Telegram and paste its token."
  read -r -s -p "Bot token: " TOKEN; echo
  if ! curl -s --max-time 15 "https://api.telegram.org/bot${TOKEN}/getMe" | grep -q '"ok":true'; then
    echo "Telegram rejected this token." >&2; exit 1
  fi

  echo "Now send any message to your bot, then press Enter."
  read -r
  CHAT_ID=$(curl -s --max-time 15 "https://api.telegram.org/bot${TOKEN}/getUpdates" \
    | grep -o '"chat":{"id":-\{0,1\}[0-9]*' | tail -1 | sed 's/.*://') || true
  if [ -z "${CHAT_ID:-}" ]; then
    read -r -p "Could not detect your chat ID. Enter it manually: " CHAT_ID
  else
    echo "Detected chat ID: $CHAT_ID"
  fi

  ( umask 077; printf 'BOT_TOKEN=%s\nCHAT_ID=%s\n' "$TOKEN" "$CHAT_ID" > "$DIR/config" )
fi

# ---- CoreLocation helper (optional) -----------------------------------------
if xcode-select -p >/dev/null 2>&1 && command -v swiftc >/dev/null 2>&1; then
  TMP="$(mktemp -d)"
  if swiftc -O "$SRC/macpingloc.swift" -o "$TMP/MacPingLoc" 2>"$TMP/swiftc.log"; then
    APP="$DIR/MacPingLoc.app"
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS"
    mv "$TMP/MacPingLoc" "$APP/Contents/MacOS/MacPingLoc"
    cat > "$APP/Contents/Info.plist" <<'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.macping.location</string>
  <key>CFBundleName</key><string>MacPingLoc</string>
  <key>CFBundleExecutable</key><string>MacPingLoc</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>NSLocationUsageDescription</key><string>macping reports this Mac's location on request.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>macping reports this Mac's location on request.</string>
  <key>NSLocationAlwaysUsageDescription</key><string>macping reports this Mac's location on request.</string>
  <key>NSLocationAlwaysAndWhenInUseUsageDescription</key><string>macping reports this Mac's location on request.</string>
</dict>
</plist>
PLIST_EOF
    codesign --force --sign - "$APP"
    LOC_BUILT=1
  else
    echo "Could not build the location helper (see $TMP/swiftc.log)." >&2
    echo "/location will fall back to IP geolocation." >&2
  fi
else
  echo "Xcode Command Line Tools not found: /location will use IP geolocation only."
  echo "(Install them with 'xcode-select --install' and re-run this script for precise location.)"
fi

# ---- LaunchAgent ------------------------------------------------------------
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$DIR/macping.sh</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardErrorPath</key><string>$DIR/err.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo
echo "macping is running. You should receive a status message in Telegram."
if [ "${LOC_BUILT:-0}" = "1" ]; then
  echo "One-time step for precise /location: run  open $DIR/MacPingLoc.app  and allow location access."
fi
