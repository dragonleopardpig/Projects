inventory=$(umbriel outputs --json)
internal=$(jq -r '[.[] | select(.name | test("^(eDP|LVDS|DSI)-"))][0].name // empty' <<< "$inventory")
mapfile -t external < <(jq -r '.[] | select(.name | test("^(eDP|LVDS|DSI)-") | not) | .name' <<< "$inventory")

if [ "${1:-}" = input ]; then
  [ -z "$internal" ] || exit 0
  focused=$(jq -r '.[] | select(.focused) | .name' <<< "$inventory")
  bus=$(ddcutil detect --terse 2>/dev/null | awk -v connector="$focused" '
    /I2C bus:/ { bus=$NF; sub(/.*\/i2c-/, "", bus) }
    /DRM connector:/ { if ($NF ~ ("-" connector "$")) { print bus; exit } }')
  [ -n "$bus" ] && ddcutil --bus "$bus" setvcp 60 0x0f
  exit 0
fi

if [ -z "$internal" ] || [ "${#external[@]}" = 0 ]; then
  noctalia msg panel-toggle control-center monitor
  exit 0
fi

panel_on=$(jq -r --arg output "$internal" '.[] | select(.name == $output) | .enabled' <<< "$inventory")
external_on=$(jq -r '[.[] | select(.name | test("^(eDP|LVDS|DSI)-") | not) | select(.enabled)] | length > 0' <<< "$inventory")
if [ "$panel_on" = true ] && [ "$external_on" = true ]; then
  for output in "${external[@]}"; do umbriel msg "output-enable:$output"; done
  umbriel msg "output-disable:$internal"
  mode="External displays"
elif [ "$panel_on" = false ]; then
  umbriel msg "output-enable:$internal"
  for output in "${external[@]}"; do umbriel msg "output-disable:$output"; done
  mode="Laptop display"
else
  for output in "${external[@]}"; do umbriel msg "output-enable:$output"; done
  umbriel msg "output-enable:$internal"
  mode="Extend displays"
fi
notify-send -a Displays -i video-display "$mode"
