#!/bin/bash
# Builds TokenBar and installs it to /Applications (or ~/Applications if that is not
# writable), so the login item points at a location that rebuilds do not delete.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/bundle.sh

DEST=/Applications
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }

pkill -x TokenBar 2>/dev/null || true
rm -rf "$DEST/TokenBar.app"
cp -R build/TokenBar.app "$DEST/TokenBar.app"
open "$DEST/TokenBar.app"
echo "Installed $DEST/TokenBar.app"
