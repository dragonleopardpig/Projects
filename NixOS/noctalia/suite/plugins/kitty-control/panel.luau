--!nonstrict
-- Kitty Terminal Control Panel
-- Full appearance, transparency, typography, cursor, and theme manager.

local M = {}

local OVERRIDES_PATH = "~/.config/kitty/overrides.conf"

-- Theme definitions
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
inactive_tab_background #090e1a
inactive_tab_foreground #a6bdc9
color0 #080d19
color1 #ff149e
color2 #00f5c8
color3 #ffd166
color4 #6bc5ff
color5 #c27dff
color6 #77f9e0
color7 #e9fff8
color8 #213846
color9 #ff4db3
color10 #77f9e0
color11 #ffe08a
color12 #8ed3ff
color13 #d0a6ff
color14 #a3f3ff
color15 #ffffff
]]
  },
  ["tokyo-night"] = {
    name = "Tokyo Night",
    accent = "#7aa2f7",
    bg = "#1a1b26",
    config = [[
foreground #c0caf5
background #1a1b26
selection_foreground #c0caf5
selection_background #283457
cursor #c0caf5
cursor_text_color #1a1b26
active_border_color #7aa2f7
inactive_border_color #292e42
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

-- Current state with defaults matching existing setup
local state = {
  opacity = 0.94,
  blur = 10,
  dynamic_opacity = true,
  font_size = 9.5,
  font_family = "CaskaydiaCove Nerd Font Mono",
  padding = 16,
  cursor_shape = "block",
  cursor_trail = 2,
  theme = "olo-neon",
  status = "Ready"
}

-- Load configuration from ~/.config/kitty/overrides.conf if it exists
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

-- Write configuration to ~/.config/kitty/overrides.conf and trigger live reload
local function applyConfig()
  local path = noctalia.expandPath(OVERRIDES_PATH)
  local themeDef = THEMES[state.theme] or THEMES["olo-neon"]

  local lines = {
    "# Auto-generated by Noctalia Kitty Control Panel",
    string.format("# Theme: %s", state.theme),
    "",
    string.format("background_opacity %.2f", state.opacity),
    string.format("background_blur %d", math.floor(state.blur + 0.5)),
    string.format("dynamic_background_opacity %s", state.dynamic_opacity and "yes" or "no"),
    string.format("font_size %.1f", state.font_size),
    string.format("font_family %s", state.font_family),
    string.format("window_padding_width %d", math.floor(state.padding + 0.5)),
    string.format("cursor_shape %s", state.cursor_shape),
    string.format("cursor_trail %d", math.floor(state.cursor_trail + 0.5)),
    "",
    "# Color Scheme",
    themeDef.config
  }

  local content = table.concat(lines, "\n")
  noctalia.writeFile(path, content)
  noctalia.runAsync("pkill -SIGUSR1 -x .kitty-wrapped || true", function(res)
    if res and res.exitCode == 0 then
      state.status = "Applied & Reloaded"
    else
      state.status = "Saved (no running kitty)"
    end
  end)
end

-- UI helper: Group card
local function card(title, iconName, children)
  local header = ui.row({ align = "center", gap = 8 }, {
    ui.glyph({ name = iconName or "adjustments", size = 16, color = "primary" }),
    ui.label({ text = title, fontSize = 13, fontWeight = "bold", color = "primary", flexGrow = 1 })
  })
  table.insert(children, 1, header)
  return ui.column({ gap = 10, padding = 12, radius = 12, fill = "surface_container" }, children)
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

  -- Top Header
  table.insert(items, ui.row({ align = "center", gap = 10, padding = 4 }, {
    ui.glyph({ name = "terminal-2", size = 22, color = "primary" }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = "Kitty Control Panel", fontSize = 16, fontWeight = "bold" }),
      ui.label({ text = state.status, fontSize = 11, color = "on_surface_variant" })
    }),
    ui.button({
      text = "Close",
      onClick = function() panel.close() end
    })
  }))

  -- 1. Appearance & Transparency Card
  local appearanceRows = {
    -- Background Opacity Slider
    ui.column({ gap = 4 }, {
      fieldHeader("Background Opacity", string.format("%d%%", math.floor(state.opacity * 100 + 0.5))),
      ui.slider({
        min = 0.20,
        max = 1.00,
        step = 0.01,
        value = state.opacity,
        onChange = function(v)
          state.opacity = tonumber(v) or state.opacity
          render()
        end,
        onDragEnd = function(v)
          state.opacity = tonumber(v) or state.opacity
          applyConfig()
          render()
        end
      })
    }),
    -- Background Blur Slider
    ui.column({ gap = 4 }, {
      fieldHeader("Background Blur", state.blur > 0 and string.format("%d px", math.floor(state.blur + 0.5)) or "Off"),
      ui.slider({
        min = 0,
        max = 30,
        step = 1,
        value = state.blur,
        onChange = function(v)
          state.blur = tonumber(v) or state.blur
          render()
        end,
        onDragEnd = function(v)
          state.blur = tonumber(v) or state.blur
          applyConfig()
          render()
        end
      })
    }),
    -- Dynamic Opacity Toggle
    ui.row({ align = "center", gap = 8 }, {
      ui.label({ text = "Dynamic Opacity (focus-dim)", fontSize = 12, flexGrow = 1 }),
      ui.toggle({
        checked = state.dynamic_opacity,
        onToggle = function(checked)
          state.dynamic_opacity = checked
          applyConfig()
          render()
        end
      })
    })
  }
  table.insert(items, card("Appearance & Transparency", "blur", appearanceRows))

  -- 2. Typography & Layout Card
  local typoRows = {
    -- Font Size Slider
    ui.column({ gap = 4 }, {
      fieldHeader("Font Size", string.format("%.1f pt", state.font_size)),
      ui.slider({
        min = 7.0,
        max = 22.0,
        step = 0.5,
        value = state.font_size,
        onChange = function(v)
          state.font_size = tonumber(v) or state.font_size
          render()
        end,
        onDragEnd = function(v)
          state.font_size = tonumber(v) or state.font_size
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
    end)(),
    -- Window Padding
    ui.column({ gap = 4 }, {
      fieldHeader("Window Padding", string.format("%d px", math.floor(state.padding + 0.5))),
      ui.slider({
        min = 0,
        max = 40,
        step = 2,
        value = state.padding,
        onChange = function(v)
          state.padding = tonumber(v) or state.padding
          render()
        end,
        onDragEnd = function(v)
          state.padding = tonumber(v) or state.padding
          applyConfig()
          render()
        end
      })
    })
  }
  table.insert(items, card("Typography & Layout", "typography", typoRows))

  -- 3. Cursor & Motion Card
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
    -- Cursor Trail Slider
    ui.column({ gap = 4 }, {
      fieldHeader("Cursor Trail Decay", state.cursor_trail > 0 and string.format("%d", math.floor(state.cursor_trail + 0.5)) or "Off"),
      ui.slider({
        min = 0,
        max = 10,
        step = 1,
        value = state.cursor_trail,
        onChange = function(v)
          state.cursor_trail = tonumber(v) or state.cursor_trail
          render()
        end,
        onDragEnd = function(v)
          state.cursor_trail = tonumber(v) or state.cursor_trail
          applyConfig()
          render()
        end
      })
    })
  }
  table.insert(items, card("Cursor & Trail", "cursor-text", cursorRows))

  -- 4. Color Themes Card
  local themeButtons = {}
  for themeId, t in pairs(THEMES) do
    local isSelected = (state.theme == themeId)
    table.insert(themeButtons, ui.button({
      text = isSelected and ("✓ " .. t.name) or t.name,
      variant = isSelected and "primary" or "secondary",
      onClick = function()
        state.theme = themeId
        applyConfig()
        render()
      end
    }))
  end
  local themeRows = {
    ui.label({ text = "Select terminal palette preset:", fontSize = 11, color = "on_surface_variant" }),
    ui.row({ gap = 6, wrap = true }, themeButtons)
  }
  table.insert(items, card("Color Palettes", "palette", themeRows))

  -- 5. Footer Actions Card
  local actionRows = {
    ui.row({ gap = 8 }, {
      ui.button({
        text = "Reload Kitty",
        variant = "primary",
        flexGrow = 1,
        onClick = function()
          applyConfig()
          render()
        end
      }),
      ui.button({
        text = "Reset Defaults",
        variant = "secondary",
        flexGrow = 1,
        onClick = function()
          state.opacity = 0.94
          state.blur = 10
          state.dynamic_opacity = true
          state.font_size = 9.5
          state.font_family = "CaskaydiaCove Nerd Font Mono"
          state.padding = 16
          state.cursor_shape = "block"
          state.cursor_trail = 2
          state.theme = "olo-neon"
          applyConfig()
          render()
        end
      })
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

loadConfig()
render()
