# End-to-end check of tray-drawer-unpinned-widgets.patch on a private headless desktop
# (its own compositor, buses, config and state; the real desktop is not touched), driven
# with a real pointer (wlrctl) the way a person would:
#   1. the clock is on the bar and no down arrow shows (the session has no tray items);
#   2. right click on the clock opens the native menu below the bar -- Open Clock, then Unpin
#      from bar -- and the clock's (long) tooltip steps aside; Unpin takes the clock off the
#      bar and the down arrow appears for it;
#   3. a click on the arrow opens the drawer, with the clock in its own colour;
#   4. right click on the clock there opens the same menu, ending with Pin to bar, while the
#      drawer stays open and the cell's tooltip steps aside; Pin puts the clock back and the
#      arrow goes.
# Colours are unique on purpose, so a screenshot's pixel counts tell what is drawn, and a
# popup is found as the region that changed between two screenshots.
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
format = "{:%A %B}"
tooltip_format = "{:%A %d %B %Y} -- a long tooltip that has to step aside for the menu"
[widget.clock.actions]
right = "widget-menu"
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
settle() { sleep 1.5; }
echo 0 > "$probe_dir/shots/counter"
# A fresh screenshot's path.  (Called in $(...), a subshell, so the number lives in a file.)
snap() {
  local shot name
  shot=$(($(cat "$probe_dir/shots/counter") + 1))
  echo "$shot" > "$probe_dir/shots/counter"
  name="shot$shot"
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
  echo "$probe_dir/shots/$name.png"
}
# Pixels of (nearly) colour $1 in a fresh screenshot, anti-aliased glyph edges included.
count() {
  local file pixels
  file=$(snap)
  pixels=$(magick "$file" -alpha off -fuzz 12% -fill black +opaque "$1" \
    -fill white -opaque "$1" -colorspace gray -format '%[fx:round(mean*w*h)]' info:)
  echo "$(basename "$file"): $1 x $pixels" >&2
  echo "$pixels"
}
# "x y": the centre of the pixels of colour $2 in screenshot $1.
centre_of() {
  local box
  box=$(magick "$1" -alpha off -fuzz 12% -fill black +opaque "$2" -fill white -opaque "$2" -format '%@' info:)
  [[ $box =~ ^([0-9]+)x([0-9]+)\+([0-9]+)\+([0-9]+)$ ]] || fail "no $2 in $1"
  echo "$((BASH_REMATCH[3] + BASH_REMATCH[1] / 2)) $((BASH_REMATCH[4] + BASH_REMATCH[2] / 2))"
}
# "x y w h": the region that changed from screenshot $1 to $2 below row $3 (default 0).
changed() {
  local box h from="${3:-0}"
  magick compare -fuzz 3% "$1" "$2" -compose src -highlight-color white -lowlight-color black \
    "$probe_dir/shots/diff.png" 2> /dev/null || true
  h=$(magick identify -format %h "$probe_dir/shots/diff.png")
  box=$(magick "$probe_dir/shots/diff.png" -alpha off -crop "x$((h - from))+0+$from" +repage -format '%@' info:)
  [[ $box =~ ^([0-9]+)x([0-9]+)\+([0-9]+)\+([0-9]+)$ && ${BASH_REMATCH[1]} -gt 1 ]] ||
    fail "nothing changed between $(basename "$1") and $(basename "$2") below row $from"
  echo "${BASH_REMATCH[3]} $((BASH_REMATCH[4] + from)) ${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
}
# Right click on the item at $1,$2 whose tooltip shows below row $3: the tooltip must be up
# first (or the check proves nothing), then the menu alone must change the screen below it.
# Prints the menu's "x y w h".
menu_at() {
  local base tip after tw mx my mw mh
  point_at 640 650
  settle
  base=$(snap)
  point_at "$1" "$2"
  settle
  tip=$(snap)
  read -r _ _ tw _ < <(changed "$base" "$tip" "$3")
  [[ $tw -gt 260 ]] || fail "test setup: no wide tooltip under the item (changed ${tw}px)"
  wlrctl pointer click right
  settle
  after=$(snap)
  read -r mx my mw mh < <(changed "$base" "$after" "$3")
  echo "menu ${mw}x${mh}+${mx}+${my} (tooltip was ${tw}px wide)" >&2
  [[ $mw -le 260 ]] || fail "the tooltip stays over the menu (changed ${mw}px wide below the item)"
  [[ $mh -gt 60 ]] || fail "the menu has one entry only (${mh}px tall): Open is missing"
  echo "$mx $my $mw $mh"
}
point_at() {
  wlrctl pointer move -5000 -5000
  wlrctl pointer move "$1" "$2"
}

# Toasts ("screenshot saved") would change the screen between shots; Do Not Disturb hides them.
noctalia msg notification-dnd-set on > /dev/null
# Umbriel greets a session without keybinds with a help box that takes the first click.
point_at 640 650
wlrctl pointer click left
settle
# 1. pinned: on the bar, no arrow
[[ $(count "$CLOCK") -gt 20 ]] || fail "the pinned clock is not on the bar"
[[ $(count "$ARROW") -eq 0 ]] || fail "a down arrow shows with nothing in the drawer"

# 2. right click on the clock: the native menu below the bar, the tooltip gone; Unpin from bar
read -r x y < <(centre_of "$(snap)" "$CLOCK")
read -r mx my mw mh < <(menu_at "$x" "$y" "$((y + 14))")
# Unpin from bar is the last entry.
point_at "$((mx + mw / 2))" "$((my + mh - 22))"
settle
wlrctl pointer click left
settle
[[ $(count "$CLOCK") -eq 0 ]] || fail "Unpin from bar left the clock on the bar"
[[ $(count "$ARROW") -gt 5 ]] || fail "no down arrow for the unpinned clock"

# 3. a click on the arrow opens the drawer, the clock in it
read -r ax ay < <(centre_of "$(snap)" "$ARROW")
point_at "$ax" "$ay"
settle
wlrctl pointer click left
settle
[[ $(count "$CLOCK") -gt 5 ]] || fail "the drawer does not show the unpinned clock in its colour"

# 4. right click on it there: the same menu, the drawer stays, the tooltip gone; Pin to bar
read -r cx cy < <(centre_of "$(snap)" "$CLOCK")
read -r mx my mw mh < <(menu_at "$cx" "$cy" "$((cy + 14))")
[[ $(count "$CLOCK") -gt 5 ]] || fail "right click closed the drawer"
# Pin to bar is the last entry.
point_at "$((mx + mw / 2))" "$((my + mh - 22))"
settle
wlrctl pointer click left
settle
[[ $(count "$CLOCK") -gt 20 ]] || fail "Pin to bar did not bring the clock back"
[[ $(count "$ARROW") -eq 0 ]] || fail "the down arrow stayed with nothing in the drawer"
echo "tray drawer: full native menus on the bar and in the drawer, tooltips step aside, drawer stays open, pin restores"
