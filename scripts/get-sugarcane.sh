#!/bin/bash
# Installs the latest Sugarcane release into Applications and opens it:
#
#   curl -fsSL https://raw.githubusercontent.com/yuvalezrati/sugarcane/main/scripts/get-sugarcane.sh | bash
#
# Run it again any time to update. You stay signed in.
set -euo pipefail

REPO="${SUGARCANE_REPO:-yuvalezrati/sugarcane}"
URL="https://github.com/$REPO/releases/latest/download/Sugarcane.zip"

# Everything runs from main, so a download that's cut off halfway does nothing.
main() {
  if [[ "$(uname)" != "Darwin" ]]; then
    echo "Sugarcane only runs on macOS."
    exit 1
  fi
  if [[ "$(sw_vers -productVersion | cut -d. -f1)" -lt 12 ]]; then
    echo "Sugarcane needs macOS 12 or later."
    exit 1
  fi

  local tmp dest
  tmp="$(mktemp -d)"
  trap "rm -rf '$tmp'" EXIT

  echo "Downloading Sugarcane…"
  if ! curl -fsSL "$URL" -o "$tmp/Sugarcane.zip"; then
    echo "Couldn't download $URL"
    exit 1
  fi
  ditto -x -k "$tmp/Sugarcane.zip" "$tmp"
  if ! codesign --verify --strict "$tmp/Sugarcane.app" 2>/dev/null; then
    echo "The download looks damaged. Please try again."
    exit 1
  fi

  dest="/Applications"
  if [[ ! -w "$dest" ]]; then
    dest="$HOME/Applications"
    mkdir -p "$dest"
  fi

  # Quit a running copy before replacing it
  pkill -x Sugarcane 2>/dev/null || true
  rm -rf "$dest/Sugarcane.app"
  ditto "$tmp/Sugarcane.app" "$dest/Sugarcane.app"

  open "$dest/Sugarcane.app"
  echo "Sugarcane is installed in $dest and running. Look for it in the menu bar."
}

main "$@"
