# Shared by the native desktop and greeter. simpledrm can be registered before
# the real GPUs when NVIDIA fbdev emulation is disabled. It has no render node:
# choosing it as wlroots' primary card makes Umbriel initialize software EGL.
configure_drm_devices() {
  local drm_sysfs="${1:-/sys/class/drm}"
  local drm_devices="${2:-/dev/dri}"
  local lid_glob="${3:-/proc/acpi/button/lid/*/state}"
  local outputs_toml="${4-}"
  local next_mode_file="${5-}"
  local config_home state_home line current_output='' output_disabled=0
  local card name render card_node render_node status conn_dir conn_name short_name
  local any_connected usable_connected config_disabled disabled_key token boot_vga score
  local lid_closed=0 lid_file lid_state='' force_internal=0 next_mode=''
  local best_score=-1 primary_card='' primary_render=''
  local -a cards=()
  local -a disabled_outputs=()

  # An explicit administrator override owns the entire GPU selection.
  if [[ -n ${WLR_DRM_DEVICES:-} || -n ${WLR_RENDER_DRM_DEVICE:-} ]]; then
    return 0
  fi

  if [[ -z $outputs_toml && ( -z ${1:-} || $drm_sysfs == /sys/class/drm ) ]]; then
    config_home="${XDG_CONFIG_HOME:-${HOME:+${HOME}/.config}}"
    if [[ -n $config_home ]]; then
      outputs_toml="$config_home/umbriel/outputs.toml"
    fi
  fi

  if [[ -z $next_mode_file && ( -z ${1:-} || $drm_sysfs == /sys/class/drm ) ]]; then
    state_home="${XDG_STATE_HOME:-${HOME:+${HOME}/.local/state}}"
    if [[ -n $state_home ]]; then
      next_mode_file="$state_home/noctalia-suite/next-display-mode"
    fi
  fi

  for lid_file in $lid_glob; do
    [[ -r $lid_file ]] || continue
    lid_state=$(< "$lid_file")
    if [[ ${lid_state,,} == *closed* ]]; then
      lid_closed=1
      break
    fi
  done

  if (( ! lid_closed )) && [[ -n $next_mode_file && -r $next_mode_file ]]; then
    next_mode=$(< "$next_mode_file")
    next_mode=${next_mode//[[:space:]]/}
    if [[ $next_mode == extend || $next_mode == laptop || $next_mode == internal ]]; then
      force_internal=1
    fi
  fi

  if [[ -n $outputs_toml && -r $outputs_toml ]]; then
    while IFS= read -r line || [[ -n $line ]]; do
      line=${line%%#*}
      if [[ $line =~ ^[[:space:]]*\[output\.\"([^\"]+)\"\][[:space:]]*$ ]] ||
         [[ $line =~ ^[[:space:]]*\[output\.([^[:space:]\".]+)\][[:space:]]*$ ]]; then
        if [[ -n $current_output ]] && (( output_disabled )); then
          disabled_outputs+=("$current_output")
        fi
        current_output=${BASH_REMATCH[1]}
        output_disabled=0
      elif [[ -n $current_output && $line =~ ^[[:space:]]*enabled[[:space:]]*=[[:space:]]*false[[:space:]]*$ ]]; then
        output_disabled=1
      elif [[ -n $current_output && $line =~ ^[[:space:]]*enabled[[:space:]]*=[[:space:]]*true[[:space:]]*$ ]]; then
        output_disabled=0
      elif [[ $line =~ ^[[:space:]]*\[ ]]; then
        if [[ -n $current_output ]] && (( output_disabled )); then
          disabled_outputs+=("$current_output")
        fi
        current_output=''
        output_disabled=0
      fi
    done < "$outputs_toml"
    if [[ -n $current_output ]] && (( output_disabled )); then
      disabled_outputs+=("$current_output")
    fi
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

    # Prefer a GPU driving an active, usable output: external ports stay
    # usable in clamshell mode or when not disabled in outputs.toml, whereas
    # built-in panels require an open lid and not being disabled in config
    # (unless a staged F7 switch requests Intel on next login).
    # Fall back to any connected output, then the firmware's boot GPU.
    # Keep every other render-capable card available for its outputs.
    any_connected=0
    usable_connected=0
    for status in "$card"-*/status; do
      [[ -r $status ]] || continue
      if [[ $(< "$status") == connected ]]; then
        any_connected=1
        conn_dir=${status%/status}
        conn_name=${conn_dir##*/}
        short_name=${conn_name#card[0-9]*-}
        config_disabled=0
        if (( ${#disabled_outputs[@]} )); then
          for disabled_key in "${disabled_outputs[@]}"; do
            if [[ $disabled_key == "$short_name" || $disabled_key == *"($short_name)" ]]; then
              config_disabled=1
              break
            fi
            if [[ -r $conn_dir/edid ]] && command -v tr >/dev/null 2>&1; then
              while IFS= read -r token; do
                (( ${#token} >= 5 )) || continue
                if [[ $disabled_key == *"$token"* ]]; then
                  config_disabled=1
                  break 2
                fi
              done < <(LC_ALL=C tr -c '[:alnum:]_-' '\n' < "$conn_dir/edid")
            fi
          done
        fi
        if [[ $conn_name =~ -(eDP|LVDS|DSI)- ]]; then
          if (( force_internal )); then
            config_disabled=0
          fi
          if (( ! lid_closed && ! config_disabled )); then
            usable_connected=1
          fi
        else
          if (( lid_closed || ! config_disabled )); then
            usable_connected=1
          fi
        fi
      fi
    done
    boot_vga=0
    if [[ -r $card/device/boot_vga && $(< "$card/device/boot_vga") == 1 ]]; then
      boot_vga=1
    fi
    score=$((usable_connected * 4 + any_connected * 2 + boot_vga))
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
