#!/bin/bash
# Builds Sugarcane and (re)starts it. Safe to run any time:
#   first run   -> builds, installs, starts at login, opens the Dexcom sign-in panel
#   later runs  -> rebuilds and restarts the running app in place
#
#   ./scripts/dev-install.sh             build + install/update
#   ./scripts/dev-install.sh uninstall   stop it and remove the app (settings and Keychain item are kept)
set -euo pipefail
cd "$(dirname "$0")/.."

LABEL="local.sugarcane"
BIN_DIR="$HOME/Applications/Sugarcane"
BIN="$BIN_DIR/Sugarcane"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/Sugarcane.log"
DOMAIN="gui/$(id -u)"

# The app was called Subar, and GlucoseBar before that. Remove those developer installs
# so only one runs.
remove_legacy() {
  local name label
  for name in Subar GlucoseBar; do
    label="local.$(echo "$name" | tr '[:upper:]' '[:lower:]')"
    if launchctl print "$DOMAIN/$label" >/dev/null 2>&1 || [[ -e "$HOME/Library/LaunchAgents/$label.plist" ]]; then
      launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
      pkill -x "$name" 2>/dev/null || true
      rm -f "$HOME/Library/LaunchAgents/$label.plist"
      rm -rf "$HOME/Applications/$name"
      echo "Removed the old $name install (your settings carry over)."
    fi
  done
}

if [[ "${1:-}" == "uninstall" ]]; then
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  pkill -x Sugarcane 2>/dev/null || true
  rm -f "$PLIST"
  rm -rf "$BIN_DIR"
  remove_legacy
  echo "Sugarcane removed. Settings kept in ~/Library/Application Support/Sugarcane/"
  exit 0
fi

if ! command -v swiftc >/dev/null; then
  echo "swiftc not found. Install the command-line tools with: xcode-select --install"
  exit 1
fi

echo "Building Sugarcane…"
mkdir -p "$BIN_DIR"
# Build to a temp file first, so a failed build never replaces the working app.
swiftc -O -parse-as-library sugarcane.swift -o "$BIN.new"
mv -f "$BIN.new" "$BIN"

remove_legacy

if [[ ! -f "$PLIST" ]]; then
  mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <!-- Restart after a crash, but not after you choose "Quit" from the menu -->
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>StandardErrorPath</key>
  <string>$LOG</string>
</dict>
</plist>
EOF
fi

if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  launchctl kickstart -k "$DOMAIN/$LABEL"
  echo "Updated and restarted."
else
  launchctl bootstrap "$DOMAIN" "$PLIST"
  echo "Installed. Sugarcane will start at login."
  echo "If you're not signed in yet, a Dexcom sign-in panel opens under the menu bar item."
fi
