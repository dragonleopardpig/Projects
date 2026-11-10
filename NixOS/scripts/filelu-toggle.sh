#!/usr/bin/env bash
set -eu

# Get current active workspace ID
ws=$(hyprctl activeworkspace -j 2>/dev/null | jq -r .id 2>/dev/null || echo "1")

# If window already exists in Hyprland
if hyprctl clients -j 2>/dev/null | jq -e '.[] | select(.class == "FileLuSync")' >/dev/null 2>&1; then
    active_class=$(hyprctl activewindow -j 2>/dev/null | jq -r .class 2>/dev/null || echo "")
    active_ws=$(hyprctl activewindow -j 2>/dev/null | jq -r .workspace.id 2>/dev/null || echo "")

    # If already focused on current workspace, toggle minimize to tray
    if [ "$active_class" = "FileLuSync" ] && [ "$active_ws" = "$ws" ]; then
        hyprctl dispatch closewindow "class:FileLuSync" >/dev/null 2>&1 || true
        exit 0
    fi

    # Otherwise bring to current workspace and focus
    hyprctl dispatch movetoworkspace "$ws,class:FileLuSync" >/dev/null 2>&1 || true
    hyprctl dispatch focuswindow "class:FileLuSync" >/dev/null 2>&1 || true
    exit 0
fi

# If window is hidden / closed to tray, wake it via D-Bus StatusNotifierItem
for bus in $(busctl --user list 2>/dev/null | awk '$3 == "FileLuSync.bin" {print $1}'); do
    busctl --user call "$bus" /StatusNotifierItem org.kde.StatusNotifierItem Activate ii 0 0 >/dev/null 2>&1 && break || true
done

# Wait for window to map, then move to current workspace and focus
for _ in {1..20}; do
    if hyprctl clients -j 2>/dev/null | jq -e '.[] | select(.class == "FileLuSync")' >/dev/null 2>&1; then
        hyprctl dispatch movetoworkspace "$ws,class:FileLuSync" >/dev/null 2>&1 || true
        hyprctl dispatch focuswindow "class:FileLuSync" >/dev/null 2>&1 || true
        exit 0
    fi
    sleep 0.05
done
