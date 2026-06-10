#!/bin/bash
# Dynamic Notch installer: builds the notch app, installs the local relay,
# and wires it to launch at login. Run from the repo's source/ directory:
#   bash install.sh
set -euo pipefail

CONF_DIR="$HOME/.dynamic-notch"
APP_DIR="$HOME/Applications/DynamicNotch"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "==> Dynamic Notch installer"

# 0. sanity
command -v swiftc >/dev/null || { echo "ERROR: swiftc not found. Install Xcode Command Line Tools: xcode-select --install"; exit 1; }
command -v python3 >/dev/null || { echo "ERROR: python3 not found."; exit 1; }

# 1. config dir
mkdir -p "$CONF_DIR"
if [ ! -f "$CONF_DIR/config.json" ]; then
  cat > "$CONF_DIR/config.json" <<'EOF'
{
  "assistant_id": "PASTE-YOUR-ASSISTANT-ID",
  "org_id": "PASTE-YOUR-ORGANIZATION-ID",
  "conversation_key": "notch"
}
EOF
  echo "==> Created $CONF_DIR/config.json - EDIT IT with your assistant_id and org_id (see README: Auth)"
fi
if [ ! -f "$CONF_DIR/session_token.txt" ]; then
  touch "$CONF_DIR/session_token.txt"
  chmod 600 "$CONF_DIR/session_token.txt"
  echo "==> Created empty $CONF_DIR/session_token.txt - paste your assistant session token into it (see README: Auth)"
fi

# 2. relay
cp "$HERE/relay.py" "$CONF_DIR/relay.py"
PLIST="$HOME/Library/LaunchAgents/ai.vellum.dynamic-notch-relay.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>ai.vellum.dynamic-notch-relay</string>
  <key>ProgramArguments</key>
  <array><string>/usr/bin/python3</string><string>$CONF_DIR/relay.py</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict>
</plist>
EOF
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
echo "==> Relay installed and running on 127.0.0.1:8473"

# 3. app bundle
mkdir -p "$APP_DIR/DynamicNotch.app/Contents/MacOS" "$APP_DIR/DynamicNotch.app/Contents/Resources"
cp "$HERE/Info.plist" "$APP_DIR/DynamicNotch.app/Contents/Info.plist"
# optional avatar + bulb face images
[ -f "$HERE/avatar.png" ] && cp "$HERE/avatar.png" "$APP_DIR/DynamicNotch.app/Contents/Resources/avatar.png" || true
[ -f "$HERE/face.png" ] && cp "$HERE/face.png" "$APP_DIR/DynamicNotch.app/Contents/Resources/face.png" || true

echo "==> Compiling (this takes ~30s)..."
swiftc -O -swift-version 5 "$HERE/main.swift" -o "$APP_DIR/DynamicNotch.app/Contents/MacOS/DynamicNotch"
codesign --force --deep --sign - "$APP_DIR/DynamicNotch.app"

# 4. launch
pkill -x DynamicNotch 2>/dev/null || true
open "$APP_DIR/DynamicNotch.app"

echo ""
echo "==> Done. The notch is live."
echo "    Click the notch to chat. Hold Control+Option to talk. ESC interrupts."
echo "    If replies fail: fill in $CONF_DIR/config.json and session_token.txt (README: Auth)."
