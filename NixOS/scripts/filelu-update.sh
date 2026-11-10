#!/usr/bin/env bash
# FileLuSync Auto-Updater for NixOS
# Updates ~/.local/opt/filelusync from ~/Downloads or fetches latest from filelu.com

set -euo pipefail

APP_DIR="$HOME/.local/opt/filelusync"
DOWNLOADS_DIR="$HOME/Downloads"
LOG_TAG="filelu-update"

log() {
    echo "[$LOG_TAG] $*"
}

notify() {
    local title="$1"
    local msg="$2"
    local urgency="${3:-normal}"
    if command -v notify-send >/dev/null 2>&1; then
        local icon="$APP_DIR/app.png"
        [ -f "$icon" ] || icon="cloud"
        notify-send -a "FileLuSync" -i "$icon" -u "$urgency" "$title" "$msg" 2>/dev/null || true
    fi
}

SOURCE_ZIP=""
SOURCE_DIR=""

if [ $# -ge 1 ] && [ -f "$1" ]; then
    SOURCE_ZIP="$1"
elif [ $# -ge 1 ] && [ -d "$1" ]; then
    SOURCE_DIR="$1"
else
    # Auto-detect in ~/Downloads
    LATEST_ZIP=$(ls -t "$DOWNLOADS_DIR"/filelusync*.zip 2>/dev/null | grep -v "\.installed$" | head -n 1 || true)
    LATEST_DIR=$(ls -td "$DOWNLOADS_DIR"/filelusync_amd 2>/dev/null | head -n 1 || true)

    if [ -n "$LATEST_ZIP" ]; then
        SOURCE_ZIP="$LATEST_ZIP"
    elif [ -n "$LATEST_DIR" ] && [ -f "$LATEST_DIR/FileLuSync.bin" ]; then
        SOURCE_DIR="$LATEST_DIR"
    fi
fi

if [ "${1:-}" = "--download" ] || [ -z "$SOURCE_ZIP" -a -z "$SOURCE_DIR" ]; then
    log "Downloading latest filelusync_amd.zip from filelu.com..."
    notify "FileLuSync" "Downloading latest update from filelu.com…"
    TMP_DL=$(mktemp -d /tmp/filelu_dl_XXXXXX)
    if curl -sSL -o "$TMP_DL/filelusync_amd.zip" "https://filelu.com/tools/filelusync_amd.zip"; then
        SOURCE_ZIP="$TMP_DL/filelusync_amd.zip"
    else
        log "Download failed."
        notify "FileLuSync Update Failed" "Could not download filelusync_amd.zip" "critical"
        exit 1
    fi
fi

log "Source detected: ${SOURCE_ZIP:-$SOURCE_DIR}"

WORK_DIR=$(mktemp -d /tmp/filelu_update_XXXXXX)

cleanup() {
    rm -rf "$WORK_DIR" 2>/dev/null || true
}
trap cleanup EXIT

if [ -n "$SOURCE_ZIP" ]; then
    log "Unpacking zip archive $SOURCE_ZIP..."
    unzip -q -o "$SOURCE_ZIP" -d "$WORK_DIR"
    BIN_DIR=$(find "$WORK_DIR" -name "FileLuSync.bin" -exec dirname {} \; | head -n 1)
    if [ -z "$BIN_DIR" ]; then
        log "Error: FileLuSync.bin not found inside $SOURCE_ZIP"
        exit 1
    fi
else
    BIN_DIR="$SOURCE_DIR"
fi

NEW_BIN="$BIN_DIR/FileLuSync.bin"
chmod +x "$NEW_BIN"

CURRENT_BIN="$APP_DIR/FileLuSync.bin"
if [ -f "$CURRENT_BIN" ] && [ "${FORCE:-0}" -ne 1 ]; then
    NEW_SIZE=$(stat -c%s "$NEW_BIN" 2>/dev/null || stat -f%z "$NEW_BIN")
    CUR_SIZE=$(stat -c%s "$CURRENT_BIN" 2>/dev/null || stat -f%z "$CURRENT_BIN")
    if [ "$NEW_SIZE" -eq "$CUR_SIZE" ]; then
        log "Installed FileLuSync.bin is already up to date ($CUR_SIZE bytes). Skipping."
        if [ $# -ge 1 ]; then
            notify "FileLuSync" "Already up to date."
        fi
        exit 0
    fi
fi

notify "FileLuSync" "Installing FileLuSync update…"

mkdir -p "$APP_DIR"

# Install updated executable
log "Installing updated binary into $APP_DIR..."
cp -f "$NEW_BIN" "$APP_DIR/FileLuSync.bin"
chmod +x "$APP_DIR/FileLuSync.bin"

if [ -f "$BIN_DIR/app.png" ]; then
    cp -f "$BIN_DIR/app.png" "$APP_DIR/app.png"
fi

# Clean up legacy app directory if present to ensure single-binary execution
rm -rf "$APP_DIR/app" 2>/dev/null || true

# Restart filelu-mount if active
if systemctl --user is-active filelu-mount.service >/dev/null 2>&1; then
    log "Restarting filelu-mount.service..."
    systemctl --user restart filelu-mount.service || true
fi

# Mark downloaded zip as processed so it doesn't trigger loops
if [ -n "$SOURCE_ZIP" ] && [ -f "$SOURCE_ZIP" ]; then
    case "$SOURCE_ZIP" in
        "$DOWNLOADS_DIR"/*)
            mv -f "$SOURCE_ZIP" "${SOURCE_ZIP}.installed" 2>/dev/null || true
            ;;
    esac
fi

if [ -d "$DOWNLOADS_DIR/filelusync_amd" ]; then
    rm -rf "$DOWNLOADS_DIR/filelusync_amd" 2>/dev/null || true
fi

log "Update completed successfully!"
notify "FileLuSync Updated" "Successfully installed latest FileLuSync update!"

if pgrep -f "FileLuSync.bin" >/dev/null 2>&1; then
    notify "FileLuSync" "FileLuSync is currently running. Restart it to load new update."
fi
