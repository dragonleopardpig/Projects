#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
HOST="${1:-auto}"
DEB_PATH="$HOME/Downloads/EasyConnect_x64_7_6_7_3.deb"
EC_DIR="$HOME/.local/opt/easyconnect/usr/share/sangfor/EasyConnect"

log() {
  printf '[easyconnect-install] %s\n' "$1"
}

if [ ! -f "$DEB_PATH" ]; then
  log "Missing .deb at: $DEB_PATH"
  log "Download it first, then re-run this script."
  exit 1
fi

log "Rebuilding NixOS for host: $HOST"
"$SCRIPT_DIR/rebuild.sh" switch "$HOST"

if [ ! -d "$EC_DIR/pango" ]; then
  log "Building bundled Pango (one-time)"
  "$HOME/.local/bin/easyconnect-pango"
else
  log "Bundled Pango already present, skipping"
fi

log "Refreshing font cache (best-effort)"
fc-cache -f >/dev/null 2>&1 || true

log "Launching EasyConnect"
"$HOME/.local/bin/easyconnect-deb"
