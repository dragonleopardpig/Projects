#!/usr/bin/env bash
set -euo pipefail
source "$1"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

reset_fixture() {
  rm -rf "$fixture/drm" "$fixture/dev" "$fixture/lid" "$fixture/outputs.toml" "$fixture/next-mode"
  mkdir -p "$fixture/drm" "$fixture/dev" "$fixture/lid"
  unset WLR_DRM_DEVICES WLR_RENDER_DRM_DEVICE
}
add_card() {
  local number=$1 render=$2 boot=$3 connected=$4 connector=${5:-HDMI-A-1}
  mkdir -p "$fixture/drm/card$number/device/drm" "$fixture/drm/card$number-$connector"
  touch "$fixture/dev/card$number"
  printf '%s\n' "$boot" > "$fixture/drm/card$number/device/boot_vga"
  printf '%s\n' "$connected" > "$fixture/drm/card$number-$connector/status"
  if [[ $render != none ]]; then
    touch "$fixture/drm/card$number/device/drm/renderD$render" "$fixture/dev/renderD$render"
  fi
}
select_devices() {
  configure_drm_devices "$fixture/drm" "$fixture/dev" "$fixture/lid/state" "$fixture/outputs.toml" "$fixture/next-mode"
}

# The failed machine: simpledrm first, NVIDIA boot GPU drives the displays,
# Intel remains available. Arbitrary card numbers catch hardcoded paths.
reset_fixture
add_card 0 none 0 connected
add_card 7 135 1 connected
add_card 12 140 0 disconnected
select_devices
[[ $WLR_DRM_DEVICES == "$fixture/dev/card7:$fixture/dev/card12" ]]
[[ $WLR_RENDER_DRM_DEVICE == "$fixture/dev/renderD135" ]]

# Firmware selects Intel, and both cards have a monitor attached.
unset WLR_DRM_DEVICES WLR_RENDER_DRM_DEVICE
printf '1\n' > "$fixture/drm/card12/device/boot_vga"
printf '0\n' > "$fixture/drm/card7/device/boot_vga"
printf 'connected\n' > "$fixture/drm/card12-HDMI-A-1/status"
select_devices
[[ $WLR_DRM_DEVICES == "$fixture/dev/card12:$fixture/dev/card7" ]]
[[ $WLR_RENDER_DRM_DEVICE == "$fixture/dev/renderD140" ]]

# A connected non-boot card beats a boot GPU with no connected outputs.
unset WLR_DRM_DEVICES WLR_RENDER_DRM_DEVICE
printf 'disconnected\n' > "$fixture/drm/card12-HDMI-A-1/status"
select_devices
[[ $WLR_RENDER_DRM_DEVICE == "$fixture/dev/renderD135" ]]

# Single GPU, no boot_vga attribute (e.g. a non-PCI platform GPU).
reset_fixture
add_card 4 132 0 connected
rm "$fixture/drm/card4/device/boot_vga"
select_devices
[[ $WLR_DRM_DEVICES == "$fixture/dev/card4" ]]
[[ $WLR_RENDER_DRM_DEVICE == "$fixture/dev/renderD132" ]]

# No monitor yet: the boot GPU still wins, rather than enumeration order.
reset_fixture
add_card 2 130 0 disconnected
add_card 9 138 1 disconnected
select_devices
[[ $WLR_DRM_DEVICES == "$fixture/dev/card9:$fixture/dev/card2" ]]
[[ $WLR_RENDER_DRM_DEVICE == "$fixture/dev/renderD138" ]]

# Missing render device and framebuffer-only systems fail clearly.
reset_fixture
add_card 0 none 0 connected
add_card 3 131 1 connected
rm "$fixture/dev/renderD131"
if select_devices; then echo 'accepted framebuffer-only graphics' >&2; exit 1; fi
[[ -z ${WLR_DRM_DEVICES:-} && -z ${WLR_RENDER_DRM_DEVICE:-} ]]

# Respect explicit deployment overrides without trying to replace them.
export WLR_DRM_DEVICES=/custom/card
select_devices
[[ $WLR_DRM_DEVICES == /custom/card && -z ${WLR_RENDER_DRM_DEVICE:-} ]]
unset WLR_DRM_DEVICES
export WLR_RENDER_DRM_DEVICE=/custom/render
select_devices
[[ $WLR_RENDER_DRM_DEVICE == /custom/render && -z ${WLR_DRM_DEVICES:-} ]]
# BIOS Auto: Intel drives eDP-1 (boot_vga=1), NVIDIA drives HDMI-A-1 (boot_vga=0).
# With lid open and no disabled outputs (Extend), Intel wins.
reset_fixture
add_card 7 135 0 connected HDMI-A-1
add_card 12 140 1 connected eDP-1
printf 'TL160ADMP26\n' > "$fixture/drm/card12-eDP-1/edid"
printf 'VP327Q\n' > "$fixture/drm/card7-HDMI-A-1/edid"
printf 'state:      open\n' > "$fixture/lid/state"
select_devices
[[ $WLR_DRM_DEVICES == "$fixture/dev/card12:$fixture/dev/card7" ]]
[[ $WLR_RENDER_DRM_DEVICE == "$fixture/dev/renderD140" ]]

# BIOS Auto with lid open and External-only in outputs.toml (eDP-1 disabled by EDID):
# NVIDIA wins for direct 60 Hz 4K scanout without cross-GPU PCIe copies.
unset WLR_DRM_DEVICES WLR_RENDER_DRM_DEVICE
cat > "$fixture/outputs.toml" <<'EOF'
[output."ASUSTek COMPUTER INC VP327Q W2LMMU003887 "]
position = [0, 0]

[output."Tianma Microelectronics Ltd. TL160ADMP26 Unknown"]
enabled = false
EOF
select_devices
[[ $WLR_DRM_DEVICES == "$fixture/dev/card7:$fixture/dev/card12" ]]
[[ $WLR_RENDER_DRM_DEVICE == "$fixture/dev/renderD135" ]]

# Staged F7 switch to Intel (next-display-mode = extend) overrides External-only when lid is open.
unset WLR_DRM_DEVICES WLR_RENDER_DRM_DEVICE
printf 'extend\n' > "$fixture/next-mode"
select_devices
[[ $WLR_DRM_DEVICES == "$fixture/dev/card12:$fixture/dev/card7" ]]
[[ $WLR_RENDER_DRM_DEVICE == "$fixture/dev/renderD140" ]]

# Staged Intel switch is ignored when lid is closed (clamshell still forces NVIDIA).
unset WLR_DRM_DEVICES WLR_RENDER_DRM_DEVICE
printf 'state:      closed\n' > "$fixture/lid/state"
select_devices
[[ $WLR_DRM_DEVICES == "$fixture/dev/card7:$fixture/dev/card12" ]]
[[ $WLR_RENDER_DRM_DEVICE == "$fixture/dev/renderD135" ]]
rm -f "$fixture/next-mode"

# BIOS Auto with lid open and Laptop-only in outputs.toml (HDMI-A-1 disabled):
# Intel wins.
unset WLR_DRM_DEVICES WLR_RENDER_DRM_DEVICE
printf 'state:      open\n' > "$fixture/lid/state"
cat > "$fixture/outputs.toml" <<'EOF'
[output."ASUSTek COMPUTER INC VP327Q W2LMMU003887 "]
enabled = false

[output."Tianma Microelectronics Ltd. TL160ADMP26 Unknown"]
position = [0, 0]
EOF
select_devices
[[ $WLR_DRM_DEVICES == "$fixture/dev/card12:$fixture/dev/card7" ]]
[[ $WLR_RENDER_DRM_DEVICE == "$fixture/dev/renderD140" ]]

# BIOS Auto with lid closed and external previously disabled in outputs.toml:
# NVIDIA still wins in clamshell mode so external monitor lights up.
unset WLR_DRM_DEVICES WLR_RENDER_DRM_DEVICE
printf 'state:      closed\n' > "$fixture/lid/state"
select_devices
[[ $WLR_DRM_DEVICES == "$fixture/dev/card7:$fixture/dev/card12" ]]
[[ $WLR_RENDER_DRM_DEVICE == "$fixture/dev/renderD135" ]]

# BIOS Auto undocked with eDP-1 disabled in outputs.toml and NVIDIA disconnected:
# Intel still wins over a disconnected dGPU so relayout can recover eDP-1.
unset WLR_DRM_DEVICES WLR_RENDER_DRM_DEVICE
cat > "$fixture/outputs.toml" <<'EOF'
[output."Tianma Microelectronics Ltd. TL160ADMP26 Unknown"]
enabled = false
EOF
printf 'disconnected\n' > "$fixture/drm/card7-HDMI-A-1/status"
select_devices
[[ $WLR_DRM_DEVICES == "$fixture/dev/card12:$fixture/dev/card7" ]]
[[ $WLR_RENDER_DRM_DEVICE == "$fixture/dev/renderD140" ]]

echo 'GPU selection checks passed'
