# End-to-end check of tray-drawer-unpinned-widgets.patch on a private headless desktop
# (its own compositor, buses, config and state; the real desktop is not touched):
#   1. the clock is on the bar and no down arrow shows (the session has no tray items);
#   2. unpinned, the clock leaves the bar and the down arrow appears for it;
#   3. the drawer shows the clock in its own colour;
#   4. pinned back, the clock returns and the arrow goes.
# Colours are unique on purpose, so a screenshot's pixel counts tell what is drawn.
CLOCK="#CCFF00"
ARROW="#FF00FF"
probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/noctalia-tray-drawer.XXXXXX")
chmod 700 "$probe_dir"
echo "Tray drawer test logs: $probe_dir"
mkdir -p "$probe_dir/config/noctalia" "$probe_dir/shots"
od -An -N32 -tx1 /dev/urandom | tr -d ' \n' > "$probe_dir/storage.key"
cat > "$probe_dir/config/noctalia/config.toml" <<EOF
[storage]
key_source = "file"
key_file = "$probe_dir/storage.key"
[shell]
setup_wizard_enabled = false
polkit_agent = false
clipboard_enabled = false
launch_apps_as_systemd_services = false
[shell.screenshot]
save_to_file = true
copy_to_clipboard = false
pipe_to_command = false
[lockscreen]
enabled = false
# Each capture posts a "saved" notification; without a daemon that call blocks the next one.
[notification]
enable_daemon = true
[wallpaper]
enabled = false
[weather]
enabled = false
[theme]
sync_color_scheme = false
[bar.main]
start = []
center = []
end = ["clock", "tray"]
[widget.clock]
color = "$CLOCK"
format = "{:%H:%M %A}"
[widget.tray]
color = "$ARROW"
drawer = true
EOF
printf '[general]\nautostart = []\nxwayland = false\n' > "$probe_dir/umbriel.toml"
# shellcheck disable=SC2016
setsid env -u WAYLAND_DISPLAY -u WAYLAND_SOCKET -u DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE \
  -u UMBRIEL_SOCKET -u XDG_SESSION_ID -u XDG_SEAT -u XDG_VTNR \
  XDG_RUNTIME_DIR="$probe_dir" WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 \
  NOCTALIA_CONFIG_HOME="$probe_dir/config" NOCTALIA_STATE_HOME="$probe_dir/state" \
  NOCTALIA_DATA_HOME="$probe_dir/data" dbus-run-session -- bash -c '
    export DBUS_SYSTEM_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS"
    exec noctalia-drm-launch umbriel -c "$1"
  ' bash "$probe_dir/umbriel.toml" > "$probe_dir/session.log" 2>&1 &
probe_pid=$!
cleanup() {
  trap - EXIT
  kill -TERM -- "-$probe_pid" 2>/dev/null || true
  for _ in {1..20}; do
    kill -0 -- "-$probe_pid" 2>/dev/null || break
    sleep 0.1
  done
  kill -KILL -- "-$probe_pid" 2>/dev/null || true
  wait "$probe_pid" 2>/dev/null || true
}
trap cleanup EXIT
export XDG_RUNTIME_DIR="$probe_dir" WAYLAND_DISPLAY=wayland-0
export UMBRIEL_SOCKET="$probe_dir/umbriel-wayland-0.sock"
export NOCTALIA_CONFIG_HOME="$probe_dir/config" NOCTALIA_STATE_HOME="$probe_dir/state"
export NOCTALIA_DATA_HOME="$probe_dir/data"
unset DISPLAY HYPRLAND_INSTANCE_SIGNATURE
for _ in {1..100}; do
  if [[ -S $UMBRIEL_SOCKET ]] && umbriel outputs --json | jq -e 'length > 0' >/dev/null; then break; fi
  sleep 0.1
done
umbriel msg "spawn:$(command -v noctalia)"
for _ in {1..100}; do
  noctalia msg status > /dev/null 2>&1 && break
  sleep 0.1
done
noctalia msg status > /dev/null

fail() {
  echo "FAIL: $*" >&2
  exit 1
}
echo 0 > "$probe_dir/shots/counter"
# Pixels of exactly this colour in a fresh full-screen screenshot.  (Called in $(...), a
# subshell, so the shot number lives in a file.)
count() {
  local shot
  shot=$(($(cat "$probe_dir/shots/counter") + 1))
  echo "$shot" > "$probe_dir/shots/counter"
  local name="shot$shot"
  # A capture still being saved drops the next request: ask again until the file lands.
  for _ in {1..5}; do
    noctalia msg screenshot-fullscreen --save-to-file --no-pipe-to-command --no-copy-to-clipboard \
      --no-annotate --no-freeze-screen --no-show-cursor --directory "$probe_dir/shots" \
      --filename-pattern "$name" --format png >> "$probe_dir/shots/msg.log" 2>&1
    for _ in {1..30}; do
      [[ -s $probe_dir/shots/$name.png ]] && break 2
      sleep 0.1
    done
  done
  [[ -s $probe_dir/shots/$name.png ]] || fail "screenshot $name was not saved"
  # Near-exact colour (anti-aliased glyph edges included), as a pixel count.
  local pixels
  pixels=$(magick "$probe_dir/shots/$name.png" -alpha off -fuzz 12% -fill black +opaque "$1" \
    -fill white -opaque "$1" -colorspace gray -format '%[fx:round(mean*w*h)]' info:)
  echo "$name: $1 x $pixels" >&2
  echo "$pixels"
}
settle() { sleep 1.5; }

settle
[[ $(count "$CLOCK") -gt 20 ]] || fail "the pinned clock is not on the bar"
[[ $(count "$ARROW") -eq 0 ]] || fail "a down arrow shows with nothing in the drawer"

noctalia msg config-set widget.clock.enabled false > /dev/null
settle
[[ $(count "$CLOCK") -eq 0 ]] || fail "the unpinned clock is still on the bar"
[[ $(count "$ARROW") -gt 5 ]] || fail "no down arrow for the unpinned clock"

noctalia msg panel-toggle tray-drawer tray > /dev/null
settle
[[ $(count "$CLOCK") -gt 5 ]] || fail "the drawer does not show the unpinned clock in its colour"
noctalia msg panel-toggle tray-drawer tray > /dev/null

noctalia msg config-set widget.clock.enabled true > /dev/null
settle
[[ $(count "$CLOCK") -gt 20 ]] || fail "the clock did not come back to the bar"
[[ $(count "$ARROW") -eq 0 ]] || fail "the down arrow stayed with nothing in the drawer"
echo "tray drawer: unpinned bar icon shown in the drawer, arrow follows it, pin restores it"
