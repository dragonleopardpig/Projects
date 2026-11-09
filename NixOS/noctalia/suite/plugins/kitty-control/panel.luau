--!nonstrict
-- Kitty Terminal Control Panel
-- Full appearance, transparency, typography, cursor, themes, and shell features (Fastfetch, ble.sh).

local M = {}

local OVERRIDES_PATH = "~/.config/kitty/overrides.conf"
local SHELL_ENV_PATH = "~/.config/kitty/shell-env.sh"

-- Color theme definitions
local THEMES = {
  ["olo-neon"] = {
    name = "OLO-Neon",
    accent = "#7df9ff",
    bg = "#07111b",
    config = [[
foreground #d9f6ff
background #07111b
selection_foreground #07111b
selection_background #7df9ff
cursor #ff63d8
cursor_text_color #07111b
active_border_color #7df9ff
inactive_border_color #152334
active_tab_background #7df9ff
active_tab_foreground #07111b
inactive_tab_background #0d1724
inactive_tab_foreground #7aa6c2
color0 #07111b
color1 #ff5ea8
color2 #4ef2c2
color3 #ffd166
color4 #6bc5ff
color5 #c27dff
color6 #7df9ff
color7 #d9f6ff
color8 #122233
color9 #ff88bf
color10 #89ffd7
color11 #ffe08a
color12 #8ed3ff
color13 #d0a6ff
color14 #a8ffff
color15 #f2fbff
]]
  },
  ["cyberpunk"] = {
    name = "Cyberpunk",
    accent = "#ff149e",
    bg = "#080d19",
    config = [[
foreground #e9fff8
background #080d19
selection_foreground #080d19
selection_background #ff149e
cursor #ff149e
cursor_text_color #080d19
active_border_color #ff149e
inactive_border_color #213846
active_tab_background #ff149e
active_tab_foreground #ffffff
inactive_tab_background #121c2e
inactive_tab_foreground #77f9e0
color0 #080d19
color1 #ff149e
color2 #00f5c8
color3 #ffd700
color4 #61e8ff
color5 #ff7e70
color6 #77f9e0
color7 #e9fff8
color8 #213846
color9 #ff54b8
color10 #5cffdc
color11 #ffe347
color12 #8aefff
color13 #ffa298
color14 #a6fbe9
color15 #ffffff
]]
  },
  ["tokyonight"] = {
    name = "Tokyo Night",
    accent = "#7aa2f7",
    bg = "#1a1b26",
    config = [[
foreground #c0caf5
background #1a1b26
selection_foreground #c0caf5
selection_background #33467c
cursor #c0caf5
cursor_text_color #1a1b26
active_border_color #7aa2f7
inactive_border_color #292e42
active_tab_background #7aa2f7
active_tab_foreground #16161e
inactive_tab_background #1f2335
inactive_tab_foreground #545c7e
color0 #15161e
color1 #f7768e
color2 #9ece6a
color3 #e0af68
color4 #7aa2f7
color5 #bb9af7
color6 #7dcfff
color7 #a9b1d6
color8 #414868
color9 #f7768e
color10 #9ece6a
color11 #e0af68
color12 #7aa2f7
color13 #bb9af7
color14 #7dcfff
color15 #c0caf5
]]
  },
  ["catppuccin"] = {
    name = "Catppuccin",
    accent = "#cba6f7",
    bg = "#1e1e2e",
    config = [[
foreground #cdd6f4
background #1e1e2e
selection_foreground #1e1e2e
selection_background #f5e0dc
cursor #f5e0dc
cursor_text_color #1e1e2e
active_border_color #b4befe
inactive_border_color #313244
active_tab_background #b4befe
active_tab_foreground #1e1e2e
inactive_tab_background #181825
inactive_tab_foreground #a6adc8
color0 #45475a
color1 #f38ba8
color2 #a6e3a1
color3 #f9e2af
color4 #89b4fa
color5 #f5c2e7
color6 #94e2d5
color7 #bac2de
color8 #585b70
color9 #f38ba8
color10 #a6e3a1
color11 #f9e2af
color12 #89b4fa
color13 #f5c2e7
color14 #94e2d5
color15 #a6adc8
]]
  },
  ["gruvbox"] = {
    name = "Gruvbox",
    accent = "#fabd2f",
    bg = "#282828",
    config = [[
foreground #ebdbb2
background #282828
selection_foreground #282828
selection_background #d5c4a1
cursor #ebdbb2
cursor_text_color #282828
active_border_color #fabd2f
inactive_border_color #3c3836
active_tab_background #fabd2f
active_tab_foreground #282828
inactive_tab_background #1d2021
inactive_tab_foreground #a89984
color0 #282828
color1 #cc241d
color2 #98971a
color3 #d79921
color4 #458588
color5 #b16286
color6 #689d6a
color7 #a89984
color8 #928374
color9 #fb4934
color10 #b8bb26
color11 #fabd2f
color12 #83a598
color13 #d3869b
color14 #8ec07c
color15 #ebdbb2
]]
  },
  ["nord"] = {
    name = "Nord",
    accent = "#88c0d0",
    bg = "#2e3440",
    config = [[
foreground #d8dee9
background #2e3440
selection_foreground #2e3440
selection_background #88c0d0
cursor #d8dee9
cursor_text_color #2e3440
active_border_color #88c0d0
inactive_border_color #3b4252
active_tab_background #88c0d0
active_tab_foreground #2e3440
inactive_tab_background #2e3440
inactive_tab_foreground #d8dee9
color0 #3b4252
color1 #bf616a
color2 #a3be8c
color3 #ebcb8b
color4 #81a1c1
color5 #b48ead
color6 #88c0d0
color7 #e5e9f0
color8 #4c566a
color9 #bf616a
color10 #a3be8c
color11 #ebcb8b
color12 #81a1c1
color13 #b48ead
color14 #8fbcbb
color15 #eceff4
]]
  }
}

-- Current state with defaults
local state = {
  -- Appearance & Window
  opacity = 0.94,
  blur = 10,
  dynamic_opacity = true,
  padding = 16,
  -- Typography
  font_size = 9.5,
  font_family = "CaskaydiaCove Nerd Font Mono",
  -- Cursor & Motion
  cursor_shape = "block",
  cursor_trail = 2,
  -- Shell features (Fastfetch & ble.sh)
  fastfetch_enabled = true,
  fastfetch_logo = "nixos", -- "nixos", "small", "none"
  ble_enabled = true,
  ble_autosuggest = true,
  ble_syntax_highlight = true,
  -- Terminal Behavior
  copy_on_select = true,
  enable_audio_bell = false,
  detect_urls = true,
  tab_bar_style = "powerline", -- "powerline", "slanted", "fade", "hidden"
  scrollback_lines = 10000,
  -- Theme & Status
  theme = "olo-neon",
  status = "Ready"
}

-- Load configuration from ~/.config/kitty/overrides.conf
local function loadConfig()
  local path = noctalia.expandPath(OVERRIDES_PATH)
  if not noctalia.fileExists(path) then
    return
  end
  local content = noctalia.readFile(path)
  if not content or content == "" then
    return
  end

  for line in string.gmatch(content .. "\n", "(.-)\n") do
    local trimmed = noctalia.string.trim(line)
    if trimmed ~= "" and string.sub(trimmed, 1, 1) ~= "#" then
      if string.find(trimmed, "^env%s+") then
        local k, v = string.match(trimmed, "^env%s+([%w_]+)=(.*)$")
        if k and v then
          v = noctalia.string.trim(v)
          if k == "FASTFETCH_ENABLED" then
            state.fastfetch_enabled = (v == "1" or v == "true")
          elseif k == "FASTFETCH_LOGO" then
            state.fastfetch_logo = v
          elseif k == "BLE_ENABLED" then
            state.ble_enabled = (v == "1" or v == "true")
          elseif k == "BLE_AUTOSUGGEST" then
            state.ble_autosuggest = (v == "1" or v == "true")
          elseif k == "BLE_SYNTAX_HIGHLIGHT" then
            state.ble_syntax_highlight = (v == "1" or v == "true")
          end
        end
      else
        local k, v = string.match(trimmed, "^([%w_]+)%s+(.+)$")
        if k and v then
          v = noctalia.string.trim(v)
          if k == "background_opacity" then
            state.opacity = tonumber(v) or state.opacity
          elseif k == "background_blur" then
            state.blur = tonumber(v) or state.blur
          elseif k == "dynamic_background_opacity" then
            state.dynamic_opacity = (v == "yes" or v == "true")
          elseif k == "font_size" then
            state.font_size = tonumber(v) or state.font_size
          elseif k == "font_family" then
            state.font_family = v
          elseif k == "window_padding_width" then
            state.padding = tonumber(v) or state.padding
          elseif k == "cursor_shape" then
            state.cursor_shape = v
          elseif k == "cursor_trail" then
            state.cursor_trail = tonumber(v) or state.cursor_trail
          elseif k == "copy_on_select" then
            state.copy_on_select = (v == "yes" or v == "true")
          elseif k == "enable_audio_bell" then
            state.enable_audio_bell = (v == "yes" or v == "true")
          elseif k == "detect_urls" then
            state.detect_urls = (v == "yes" or v == "true")
          elseif k == "tab_bar_style" then
            state.tab_bar_style = v
          elseif k == "scrollback_lines" then
            state.scrollback_lines = tonumber(v) or state.scrollback_lines
          end
        end
      end
    elseif string.find(trimmed, "^# Theme:%s*") then
      local t = string.match(trimmed, "^# Theme:%s*(.+)$")
      if t and THEMES[t] then
        state.theme = t
      end
    end
  end
end

-- Write configuration to overrides.conf and shell-env.sh, then trigger live reload
local function applyConfig()
  local path = noctalia.expandPath(OVERRIDES_PATH)
  local shellEnvPath = noctalia.expandPath(SHELL_ENV_PATH)
  local themeDef = THEMES[state.theme] or THEMES["olo-neon"]

  local lines = {
    "# Auto-generated by Noctalia Kitty Control Panel",
    string.format("# Theme: %s", state.theme),
    "",
    "# Appearance & Window",
    string.format("background_opacity %.2f", state.opacity),
    string.format("background_blur %d", math.floor(state.blur + 0.5)),
    string.format("dynamic_background_opacity %s", state.dynamic_opacity and "yes" or "no"),
    string.format("window_padding_width %d", math.floor(state.padding + 0.5)),
    "",
    "# Typography",
    string.format("font_size %.1f", state.font_size),
    string.format("font_family %s", state.font_family),
    "",
    "# Cursor & Motion",
    string.format("cursor_shape %s", state.cursor_shape),
    string.format("cursor_trail %d", math.floor(state.cursor_trail + 0.5)),
    "",
    "# Terminal Behavior",
    string.format("copy_on_select %s", state.copy_on_select and "yes" or "no"),
    string.format("enable_audio_bell %s", state.enable_audio_bell and "yes" or "no"),
    string.format("detect_urls %s", state.detect_urls and "yes" or "no"),
    string.format("tab_bar_style %s", state.tab_bar_style),
    string.format("scrollback_lines %d", math.floor(state.scrollback_lines + 0.5)),
    "",
    "# Shell Environment & Features (Fastfetch, ble.sh)",
    string.format("env FASTFETCH_ENABLED=%s", state.fastfetch_enabled and "1" or "0"),
    string.format("env FASTFETCH_LOGO=%s", state.fastfetch_logo),
    string.format("env BLE_ENABLED=%s", state.ble_enabled and "1" or "0"),
    string.format("env BLE_AUTOSUGGEST=%s", state.ble_autosuggest and "1" or "0"),
    string.format("env BLE_SYNTAX_HIGHLIGHT=%s", state.ble_syntax_highlight and "1" or "0"),
    "",
    "# Color Scheme",
    themeDef.config
  }

  local content = table.concat(lines, "\n")
  noctalia.writeFile(path, content)

  -- Write shell-env.sh for bash subshells and .bashrc integration
  local shellLines = {
    "# Auto-generated by Noctalia Kitty Control Panel",
    string.format("export FASTFETCH_ENABLED=%s", state.fastfetch_enabled and "1" or "0"),
    string.format("export FASTFETCH_LOGO=%q", state.fastfetch_logo),
    string.format("export BLE_ENABLED=%s", state.ble_enabled and "1" or "0"),
    string.format("export BLE_AUTOSUGGEST=%s", state.ble_autosuggest and "1" or "0"),
    string.format("export BLE_SYNTAX_HIGHLIGHT=%s", state.ble_syntax_highlight and "1" or "0"),
    ""
  }
  noctalia.writeFile(shellEnvPath, table.concat(shellLines, "\n"))

  -- Signal Kitty windows to reload instantly
  noctalia.runAsync("pkill -SIGUSR1 -x .kitty-wrapped || true", function(res)
    if res and res.exitCode == 0 then
      state.status = "Applied & Reloaded"
    else
      state.status = "Saved (no running kitty)"
    end
    render()
  end)
end

-- UI helper: Group card
local function card(title, iconName, children)
  local header = ui.row({ align = "center", gap = 8 }, {
    ui.glyph({ name = iconName or "adjustments", size = 16, color = "primary" }),
    ui.label({ text = title, fontSize = 13, fontWeight = "bold", color = "primary", flexGrow = 1 })
  })
  local rows = { header }
  for _, c in ipairs(children) do
    table.insert(rows, c)
  end
  return ui.column({ gap = 10, padding = 12, radius = 12, fill = "surface_container" }, rows)
end

-- UI helper: Label + Value header row
local function fieldHeader(label, valueStr)
  return ui.row({ align = "center", gap = 8 }, {
    ui.label({ text = label, fontSize = 12, fontWeight = "medium", flexGrow = 1 }),
    ui.label({ text = valueStr, fontSize = 12, fontWeight = "bold", color = "primary" })
  })
end

local render

render = function()
  local items = {}

  -- 1. Header Bar
  local headerRow = ui.row({ align = "center", justify = "space_between" }, {
    ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = "terminal-2", size = 22, color = "primary" }),
      ui.label({ text = "Kitty Control", fontSize = 16, fontWeight = "bold" })
    }),
    ui.label({ text = state.status, fontSize = 11, color = "on_surface_variant" })
  })
  table.insert(items, headerRow)

  -- 2. Fastfetch System Info Card
  local fastfetchRows = {
    -- Fastfetch on Startup toggle
    ui.row({ align = "center", justify = "space_between" }, {
      ui.column({ gap = 2 }, {
        ui.label({ text = "Fastfetch on Shell Launch", fontSize = 12, fontWeight = "medium" }),
        ui.label({ text = "Print system specs banner on terminal open", fontSize = 10, color = "on_surface_variant" })
      }),
      ui.toggle({
        value = state.fastfetch_enabled,
        onToggle = function(v)
          state.fastfetch_enabled = (v == true or v == "true")
          applyConfig()
          render()
        end
      })
    }),
    -- Fastfetch Logo Mode
    ui.column({ gap = 6 }, {
      fieldHeader("Banner Logo Style", ""),
      ui.row({ gap = 8 }, {
        ui.button({
          text = "󰣇 Cyberpunk",
          variant = (state.fastfetch_logo == "nixos") and "primary" or "tonal",
          selected = (state.fastfetch_logo == "nixos"),
          enabled = state.fastfetch_enabled,
          flexGrow = 1,
          onClick = function()
            state.fastfetch_logo = "nixos"
            applyConfig()
            render()
          end
        }),
        ui.button({
          text = "󰣇 Compact",
          variant = (state.fastfetch_logo == "small") and "primary" or "tonal",
          selected = (state.fastfetch_logo == "small"),
          enabled = state.fastfetch_enabled,
          flexGrow = 1,
          onClick = function()
            state.fastfetch_logo = "small"
            applyConfig()
            render()
          end
        }),
        ui.button({
          text = "󰅂 Text Only",
          variant = (state.fastfetch_logo == "none") and "primary" or "tonal",
          selected = (state.fastfetch_logo == "none"),
          enabled = state.fastfetch_enabled,
          flexGrow = 1,
          onClick = function()
            state.fastfetch_logo = "none"
            applyConfig()
            render()
          end
        })
      })
    }),
    -- Run Fastfetch Test Button
    ui.button({
      text = "  Run Fastfetch in Terminal",
      glyph = "player-play",
      variant = "tonal",
      onClick = function()
        noctalia.runAsync("kitty --hold fastfetch &")
      end
    })
  }
  table.insert(items, card("Fastfetch System Info", "device-desktop", fastfetchRows))

  -- 3. ble.sh (Bash Line Editor) Card
  local bleRows = {
    -- ble.sh Master Toggle
    ui.row({ align = "center", justify = "space_between" }, {
      ui.column({ gap = 2 }, {
        ui.label({ text = "ble.sh Enhanced Shell", fontSize = 12, fontWeight = "medium" }),
        ui.label({ text = "Fish-style autosuggestions & syntax highlighting in bash", fontSize = 10, color = "on_surface_variant" })
      }),
      ui.toggle({
        value = state.ble_enabled,
        onToggle = function(v)
          state.ble_enabled = (v == true or v == "true")
          applyConfig()
          render()
        end
      })
    }),
    -- Ghost Autosuggestions Toggle
    ui.row({ align = "center", justify = "space_between" }, {
      ui.column({ gap = 2 }, {
        ui.label({ text = "Autosuggestions (Ghost Text)", fontSize = 12, fontWeight = "medium" }),
        ui.label({ text = "History-based suggestions as you type (Tab to accept)", fontSize = 10, color = "on_surface_variant" })
      }),
      ui.toggle({
        value = state.ble_autosuggest,
        enabled = state.ble_enabled,
        onToggle = function(v)
          state.ble_autosuggest = (v == true or v == "true")
          applyConfig()
          render()
        end
      })
    }),
    -- Syntax Highlighting Toggle
    ui.row({ align = "center", justify = "space_between" }, {
      ui.column({ gap = 2 }, {
        ui.label({ text = "Real-time Syntax Highlighting", fontSize = 12, fontWeight = "medium" }),
        ui.label({ text = "Colorize commands, arguments, strings, and errors live", fontSize = 10, color = "on_surface_variant" })
      }),
      ui.toggle({
        value = state.ble_syntax_highlight,
        enabled = state.ble_enabled,
        onToggle = function(v)
          state.ble_syntax_highlight = (v == true or v == "true")
          applyConfig()
          render()
        end
      })
    })
  }
  table.insert(items, card("ble.sh Line Editor", "sparkles", bleRows))

  -- 4. Appearance & Window Card
  local appRows = {
    -- Opacity Slider
    ui.column({ gap = 4 }, {
      fieldHeader("Background Opacity", string.format("%d%%", math.floor(state.opacity * 100 + 0.5))),
      ui.slider({
        key = "slider_opacity",
        min = 0.20,
        max = 1.00,
        step = 0.02,
        value = state.opacity,
        onChange = function(v)
          local num = tonumber(v)
          if num then
            state.opacity = num
            render()
          end
        end,
        onDragEnd = function()
          applyConfig()
          render()
        end
      })
    }),
    -- Background Blur Slider
    ui.column({ gap = 4 }, {
      fieldHeader("Background Blur", string.format("%d px", math.floor(state.blur + 0.5))),
      ui.slider({
        key = "slider_blur",
        min = 0,
        max = 30,
        step = 1,
        value = state.blur,
        onChange = function(v)
          local num = tonumber(v)
          if num then
            state.blur = num
            render()
          end
        end,
        onDragEnd = function()
          applyConfig()
          render()
        end
      })
    }),
    -- Dynamic Opacity Toggle
    ui.row({ align = "center", justify = "space_between" }, {
      ui.column({ gap = 2 }, {
        ui.label({ text = "Dynamic Opacity", fontSize = 12, fontWeight = "medium" }),
        ui.label({ text = "Allow apps/scripts to modulate background transparency", fontSize = 10, color = "on_surface_variant" })
      }),
      ui.toggle({
        value = state.dynamic_opacity,
        onToggle = function(v)
          state.dynamic_opacity = (v == true or v == "true")
          applyConfig()
          render()
        end
      })
    }),
    -- Window Padding Slider
    ui.column({ gap = 4 }, {
      fieldHeader("Window Padding", string.format("%d px", math.floor(state.padding + 0.5))),
      ui.slider({
        key = "slider_padding",
        min = 0,
        max = 40,
        step = 2,
        value = state.padding,
        onChange = function(v)
          local num = tonumber(v)
          if num then
            state.padding = num
            render()
          end
        end,
        onDragEnd = function()
          applyConfig()
          render()
        end
      })
    })
  }
  table.insert(items, card("Appearance & Transparency", "palette", appRows))

  -- 5. Typography & Font Card
  local typoRows = {
    -- Font Size Slider
    ui.column({ gap = 4 }, {
      fieldHeader("Font Size", string.format("%.1f pt", state.font_size)),
      ui.slider({
        key = "slider_font_size",
        min = 7.0,
        max = 24.0,
        step = 0.5,
        value = state.font_size,
        onChange = function(v)
          local num = tonumber(v)
          if num then
            state.font_size = num
            render()
          end
        end,
        onDragEnd = function()
          applyConfig()
          render()
        end
      })
    }),
    -- Font Family Select
    (function()
      local fontOptions = { "CaskaydiaCove Nerd Font Mono", "JetBrains Mono", "FiraCode Nerd Font", "Inter" }
      local fontIdx = 0
      for idx, name in ipairs(fontOptions) do
        if name == state.font_family then
          fontIdx = idx - 1
          break
        end
      end
      return ui.column({ gap = 4 }, {
        fieldHeader("Font Family", ""),
        ui.select({
          options = fontOptions,
          selectedIndex = fontIdx,
          onChange = function(idxStr, text)
            if text and text ~= "" then
              state.font_family = text
            elseif idxStr then
              local i = (tonumber(idxStr) or 0) + 1
              state.font_family = fontOptions[i] or state.font_family
            end
            applyConfig()
            render()
          end
        })
      })
    end)()
  }
  table.insert(items, card("Typography & Font", "typography", typoRows))

  -- 6. Cursor & Motion Card
  local cursorRows = {
    -- Cursor Shape Buttons
    ui.column({ gap = 6 }, {
      fieldHeader("Cursor Shape", ""),
      ui.row({ gap = 8 }, {
        ui.button({
          text = "█ Block",
          variant = (state.cursor_shape == "block") and "primary" or "tonal",
          selected = (state.cursor_shape == "block"),
          flexGrow = 1,
          onClick = function()
            state.cursor_shape = "block"
            applyConfig()
            render()
          end
        }),
        ui.button({
          text = "❘ Beam",
          variant = (state.cursor_shape == "beam") and "primary" or "tonal",
          selected = (state.cursor_shape == "beam"),
          flexGrow = 1,
          onClick = function()
            state.cursor_shape = "beam"
            applyConfig()
            render()
          end
        }),
        ui.button({
          text = "  Underline",
          variant = (state.cursor_shape == "underline") and "primary" or "tonal",
          selected = (state.cursor_shape == "underline"),
          flexGrow = 1,
          onClick = function()
            state.cursor_shape = "underline"
            applyConfig()
            render()
          end
        })
      })
    }),
    -- Cursor Trail Decay Slider
    ui.column({ gap = 4 }, {
      fieldHeader("Cursor Trail Decay", state.cursor_trail > 0 and string.format("%d", math.floor(state.cursor_trail + 0.5)) or "Off"),
      ui.slider({
        key = "slider_cursor_trail",
        min = 0,
        max = 10,
        step = 1,
        value = state.cursor_trail,
        onChange = function(v)
          local num = tonumber(v)
          if num then
            state.cursor_trail = num
            render()
          end
        end,
        onDragEnd = function()
          applyConfig()
          render()
        end
      })
    })
  }
  table.insert(items, card("Cursor & Motion", "pointer", cursorRows))

  -- 7. Terminal Behavior Card
  local behaviorRows = {
    -- Copy on Select
    ui.row({ align = "center", justify = "space_between" }, {
      ui.column({ gap = 2 }, {
        ui.label({ text = "Copy on Select", fontSize = 12, fontWeight = "medium" }),
        ui.label({ text = "Automatically copy highlighted text to system clipboard", fontSize = 10, color = "on_surface_variant" })
      }),
      ui.toggle({
        value = state.copy_on_select,
        onToggle = function(v)
          state.copy_on_select = (v == true or v == "true")
          applyConfig()
          render()
        end
      })
    }),
    -- Audio Bell
    ui.row({ align = "center", justify = "space_between" }, {
      ui.column({ gap = 2 }, {
        ui.label({ text = "Audio Bell", fontSize = 12, fontWeight = "medium" }),
        ui.label({ text = "Play alert chime on terminal BEL character", fontSize = 10, color = "on_surface_variant" })
      }),
      ui.toggle({
        value = state.enable_audio_bell,
        onToggle = function(v)
          state.enable_audio_bell = (v == true or v == "true")
          applyConfig()
          render()
        end
      })
    }),
    -- Detect URLs
    ui.row({ align = "center", justify = "space_between" }, {
      ui.column({ gap = 2 }, {
        ui.label({ text = "Clickable URLs", fontSize = 12, fontWeight = "medium" }),
        ui.label({ text = "Underline web links on hover and open in browser", fontSize = 10, color = "on_surface_variant" })
      }),
      ui.toggle({
        value = state.detect_urls,
        onToggle = function(v)
          state.detect_urls = (v == true or v == "true")
          applyConfig()
          render()
        end
      })
    }),
    -- Tab Bar Style
    ui.column({ gap = 6 }, {
      fieldHeader("Tab Bar Style", state.tab_bar_style),
      ui.row({ gap = 6 }, {
        ui.button({
          text = "Powerline",
          variant = (state.tab_bar_style == "powerline") and "primary" or "tonal",
          selected = (state.tab_bar_style == "powerline"),
          flexGrow = 1,
          onClick = function()
            state.tab_bar_style = "powerline"
            applyConfig()
            render()
          end
        }),
        ui.button({
          text = "Slanted",
          variant = (state.tab_bar_style == "slanted") and "primary" or "tonal",
          selected = (state.tab_bar_style == "slanted"),
          flexGrow = 1,
          onClick = function()
            state.tab_bar_style = "slanted"
            applyConfig()
            render()
          end
        }),
        ui.button({
          text = "Fade",
          variant = (state.tab_bar_style == "fade") and "primary" or "tonal",
          selected = (state.tab_bar_style == "fade"),
          flexGrow = 1,
          onClick = function()
            state.tab_bar_style = "fade"
            applyConfig()
            render()
          end
        }),
        ui.button({
          text = "Hidden",
          variant = (state.tab_bar_style == "hidden") and "primary" or "tonal",
          selected = (state.tab_bar_style == "hidden"),
          flexGrow = 1,
          onClick = function()
            state.tab_bar_style = "hidden"
            applyConfig()
            render()
          end
        })
      })
    }),
    -- Scrollback Lines
    ui.column({ gap = 4 }, {
      fieldHeader("Scrollback Buffer", string.format("%s lines", tostring(math.floor(state.scrollback_lines + 0.5)))),
      ui.slider({
        key = "slider_scrollback",
        min = 2000,
        max = 50000,
        step = 1000,
        value = state.scrollback_lines,
        onChange = function(v)
          local num = tonumber(v)
          if num then
            state.scrollback_lines = num
            render()
          end
        end,
        onDragEnd = function()
          applyConfig()
          render()
        end
      })
    })
  }
  table.insert(items, card("Terminal Behavior", "settings", behaviorRows))

  -- 8. Color Themes Card
  local themeGrid = {}
  local themeKeys = { "olo-neon", "cyberpunk", "tokyonight", "catppuccin", "gruvbox", "nord" }

  for i = 1, #themeKeys, 2 do
    local k1 = themeKeys[i]
    local k2 = themeKeys[i + 1]
    local t1 = THEMES[k1]
    local t2 = THEMES[k2]

    local rowChildren = {}
    if t1 then
      table.insert(rowChildren, ui.button({
        text = t1.name,
        variant = (state.theme == k1) and "primary" or "tonal",
        selected = (state.theme == k1),
        flexGrow = 1,
        onClick = function()
          state.theme = k1
          applyConfig()
          render()
        end
      }))
    end
    if t2 then
      table.insert(rowChildren, ui.button({
        text = t2.name,
        variant = (state.theme == k2) and "primary" or "tonal",
        selected = (state.theme == k2),
        flexGrow = 1,
        onClick = function()
          state.theme = k2
          applyConfig()
          render()
        end
      }))
    end
    table.insert(themeGrid, ui.row({ gap = 8 }, rowChildren))
  end
  table.insert(items, card("Color Themes", "color-swatch", themeGrid))

  -- 9. Footer Actions
  local actionRows = {
    ui.row({ gap = 8 }, {
      ui.button({
        text = "New Terminal",
        glyph = "terminal-2",
        variant = "primary",
        flexGrow = 1,
        onClick = function()
          noctalia.runAsync("kitty &")
        end
      }),
      ui.button({
        text = "Reload Windows",
        glyph = "refresh",
        variant = "tonal",
        flexGrow = 1,
        onClick = function()
          applyConfig()
        end
      })
    }),
    ui.button({
      text = "Reset to Defaults",
      glyph = "rotate-ccw",
      variant = "tonal",
      onClick = function()
        state.opacity = 0.94
        state.blur = 10
        state.dynamic_opacity = true
        state.padding = 16
        state.font_size = 9.5
        state.font_family = "CaskaydiaCove Nerd Font Mono"
        state.cursor_shape = "block"
        state.cursor_trail = 2
        state.fastfetch_enabled = true
        state.fastfetch_logo = "nixos"
        state.ble_enabled = true
        state.ble_autosuggest = true
        state.ble_syntax_highlight = true
        state.copy_on_select = true
        state.enable_audio_bell = false
        state.detect_urls = true
        state.tab_bar_style = "powerline"
        state.scrollback_lines = 10000
        state.theme = "olo-neon"
        applyConfig()
        render()
      end
    })
  }
  table.insert(items, ui.column({ gap = 6 }, actionRows))

  -- Render the full scrollable view
  panel.render(ui.scroll({ flexGrow = 1, gap = 12, padding = 12 }, items))
end

function onOpen(_context)
  loadConfig()
  state.status = "Ready"
  render()
end

M.onOpen = onOpen
return M
