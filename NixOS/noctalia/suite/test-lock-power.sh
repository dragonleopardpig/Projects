# Run the actual shell/locker and compositor together, without touching the
# desktop's outputs, buses, lock hint, clipboard or persistent preferences.
probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/noctalia-lock-power.XXXXXX")
chmod 700 "$probe_dir"
echo "Lock/power test logs: $probe_dir"
mkdir -p "$probe_dir/config/noctalia"
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
[lockscreen]
enabled = true
grace_period_seconds = 0
[notification]
enable_daemon = false
[wallpaper]
enabled = false
[weather]
enabled = false
[theme]
sync_color_scheme = false
EOF
printf '[general]\nautostart = []\nxwayland = false\n' > "$probe_dir/umbriel.toml"
# Expand the bus address inside dbus-run-session, after it creates the bus.
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
helper_pid=''
cleanup() {
  trap - EXIT
  [[ -z $helper_pid ]] || kill "$helper_pid" 2>/dev/null || true
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
  if noctalia msg status > "$probe_dir/status.json" 2>/dev/null; then break; fi
  sleep 0.1
done
jq -e '.locked == false' "$probe_dir/status.json" >/dev/null
powered() { umbriel outputs --json | jq -er '.[0].powered | tostring'; }
[[ $(powered) == true ]]
# Skip only the real system's lid inhibitor: the test's virtual display must
# not acquire a host logind lock. The lock and power commands are unchanged.
noctalia-lock-and-blank --inhibited > "$probe_dir/lock-helper.log" 2>&1 &
helper_pid=$!
for _ in {1..100}; do
  [[ $(powered) == false ]] && break
  sleep 0.1
done
[[ $(powered) == false ]]
noctalia msg status | jq -e '.locked == true' >/dev/null
echo 'F1 helper: Noctalia locked the session and powered the display off'
wlrctl pointer move 100 50
wlrctl pointer click left
wlrctl pointer scroll 10 0
sleep 0.2
[[ $(powered) == false ]]
echo 'Locked screen: mouse motion, click and scroll did not wake the display'
wtype -k Shift_L
sleep 0.2
[[ $(powered) == true ]]
noctalia msg status | jq -e '.locked == true' >/dev/null
echo 'Keyboard woke the display; the session remained locked'
wait "$helper_pid"
helper_pid=''
