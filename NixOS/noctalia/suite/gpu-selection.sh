# Shared by the native desktop and greeter. simpledrm can be registered before
# the real GPUs when NVIDIA fbdev emulation is disabled. It has no render node:
# choosing it as wlroots' primary card makes Umbriel initialize software EGL.
configure_drm_devices() {
  local drm_sysfs="${1:-/sys/class/drm}"
  local drm_devices="${2:-/dev/dri}"
  local card name render card_node render_node status connected boot_vga score
  local best_score=-1 primary_card='' primary_render=''
  local -a cards=()

  # An explicit administrator override owns the entire GPU selection.
  if [[ -n ${WLR_DRM_DEVICES:-} || -n ${WLR_RENDER_DRM_DEVICE:-} ]]; then
    return 0
  fi

  for card in "$drm_sysfs"/card[0-9]*; do
    name=${card##*/}
    [[ $name =~ ^card[0-9]+$ ]] || continue
    card_node="$drm_devices/$name"
    [[ -e $card_node ]] || continue
    render_node=''
    for render in "$card"/device/drm/renderD[0-9]*; do
      [[ -e $render && -e $drm_devices/${render##*/} ]] || continue
      render_node="$drm_devices/${render##*/}"
      break
    done
    [[ -n $render_node ]] || continue

    # Prefer a GPU attached to a connected display, then the firmware's boot
    # GPU. Keep every other render-capable card available for its outputs.
    connected=0
    for status in "$card"-*/status; do
      [[ -r $status ]] || continue
      if [[ $(< "$status") == connected ]]; then connected=1; break; fi
    done
    boot_vga=0
    if [[ -r $card/device/boot_vga && $(< "$card/device/boot_vga") == 1 ]]; then
      boot_vga=1
    fi
    score=$((connected * 2 + boot_vga))
    cards+=("$card_node")
    if ((score > best_score)); then
      best_score=$score
      primary_card=$card_node
      primary_render=$render_node
    fi
  done

  if [[ -z $primary_card ]]; then
    echo 'Noctalia: no DRM card with a render node found; refusing framebuffer-only graphics.' >&2
    return 1
  fi
  WLR_DRM_DEVICES=$primary_card
  for card_node in "${cards[@]}"; do
    [[ $card_node == "$primary_card" ]] || WLR_DRM_DEVICES+=":$card_node"
  done
  export WLR_DRM_DEVICES
  export WLR_RENDER_DRM_DEVICE="$primary_render"
  echo "Noctalia: DRM devices=$WLR_DRM_DEVICES; renderer=$WLR_RENDER_DRM_DEVICE" >&2
}
