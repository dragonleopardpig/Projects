# Daily shortcuts in Noctalia Suite

The existing Hyprland bindings in `home.nix` are the source for these bindings.
`Mod` is **Super** in the Noctalia Suite session.

## Familiar applications

| Shortcut | Action |
| --- | --- |
| Super+F | Firefox |
| Super+Q | Kitty |
| Super+E | Emacs |
| Super+P | Proton VPN |
| Super+W | Walker |
| Super+B | btop in Kitty |
| Super+N | Existing Nemo wrapper |
| Super+S | Sioyek, new window |
| Super+Y | Yazi in Kitty |
| Super+M | Minder |
| Super+T | Toggle terminal scratchpad |
| Super+V | Toggle Pavucontrol scratchpad |
| Super+X | Toggle Xed scratchpad |

The three scratchpads use Umbriel's native launch/show/hide behavior. Pyprland
is not needed in this session.

## Windows, workspaces, shell

Umbriel uses the dwindle layout by default.

| Shortcut | Action |
| --- | --- |
| Super+arrows | Focus in that direction, crossing outputs at an edge |
| Super+Shift+arrows | Move the focused tile in that direction |
| Super+Alt+T | Toggle the focused tile's split direction |
| Super+K | Close focused window |
| Super+Shift+F | Maximize the column/window |
| Super+1…9 | Select that workspace on the current output |
| Super+Shift+1…9 | Move window to that workspace |
| Ctrl+Alt+Left / Right | Previous / next workspace on current output |
| Alt+Tab | Noctalia MRU window switcher |
| Super+Tab | Previous window in layout order |
| Super+left drag / right drag | Move / resize (native Umbriel behavior) |
| Super+middle click | Toggle floating |
| Super+Z | Maximize to the output edges (window zoom) |
| Pause | Workspace/window overview |
| Super+A | Reload Noctalia's configuration |
| Super+Shift+A | Toggle the Noctalia bar |
| Super+Escape | Exit session, with compositor confirmation |

## Screenshots and hardware keys

| Shortcut | Action |
| --- | --- |
| Print | Select screenshot region |
| Shift+Print | All-monitor screenshot |
| Ctrl+Print | Pick screenshot monitor |
| Alt+Print | Screenshot focused window |
| Super+Shift+Escape | Stop wf-recorder and notify saved path |
| Volume / mute / microphone-mute keys | Native Noctalia controls and OSD |
| Media play / pause / next / previous keys | Native media controls |
| F5 / F6, brightness keys | Brightness down / up for the selected monitor |
| F1, Super+L, Ctrl+Alt+L | Lock, then power off monitors; keyboard-only wake |
| F7, display-switch key | Cycle external-only, internal-only, extended displays |
| F8 | DDC input 0x0f on a desktop without an internal panel |
| Super+F7 | Restore Sioyek keyboard lighting |

Screenshot captures open Swappy, preserving the existing annotation workflow.
The display-cycle helper enables the destination before disabling any output.
With one display, F7 opens Noctalia's Monitor controls. F8 detects hardware at
runtime and leaves laptop inputs alone.

## Additional Suite shortcuts

| Shortcut | Action |
| --- | --- |
| Super+Return | OLO-Neon Foot terminal |
| Super+Shift+N | Strata file browser |
| Super+Space | Full-screen app grid and search (also the bar's NixOS snowflake) |
| Super+Shift+V | Clipboard history |
| Super+Comma | Settings and theme selection |
| Super+Shift+W | Wallpaper picker |
| Super+Shift+E | Session menu |
| Super+O | Overview |
| Super+L | Lock and power off monitors |
| Super+Ctrl+F | True fullscreen |
| Super+Shift+T | Toggle floating |
| Super+Shift+arrows | Move window/column |
| Super+R | Cycle column width |

## Compositor differences

- Pypr's pixel magnifier is not available in the pinned Umbriel version;
  Super+Z provides window zoom by maximizing to the display edges.
- Umbriel owns workspaces per output, so numbers refer to positions on the
  current display rather than Hyprland's globally numbered/swapped workspaces.
- F7 supports internal-only, external-only, and extended modes. This pinned
  compositor does not expose a mirror action, so duplicate mode is omitted.
- Use Super+right drag for resizing. Hyprland's alternate Super+Alt+left-drag
  resize gesture is not configurable in this Umbriel version.
- Super+A reloads shell configuration; it does not restart a stuck process.
- F1/Super+L/Ctrl+Alt+L use Noctalia's native lock and wait for a safe lock frame
  before powering displays off. The suite patches Umbriel so mouse motion,
  clicks, scrolling, touch and gestures do not wake DPMS-off outputs; a keyboard
  press does. The compositor change takes effect when a new session starts.
