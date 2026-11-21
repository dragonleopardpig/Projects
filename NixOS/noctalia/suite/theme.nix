{ pkgs }:
let
  neon = "#FF149E";
  dark = {
    # Filled controls use Olo-inspired teal with dark, high-contrast text.
    # Magenta is a separate decorative accent for outlines and curves.
    primary = "#00F5C8"; on_primary = "#00251F";
    secondary = "#77F9E0"; on_secondary = "#032C25";
    tertiary = "#61E8FF"; on_tertiary = "#002932";
    error = "#FF6B87"; on_error = "#370018";
    surface = "#080D19"; on_surface = "#E9FFF8";
    surface_container = "#121C2E"; on_surface_variant = "#A6BDC9";
    outline_variant = "#2A4757"; shadow = "#00040B";
    hover = "#164A43"; on_hover = "#C8FFF0";
    terminal = {
      background = "#080D19"; foreground = "#E9FFF8";
      cursor = "#00F5C8"; cursor_text = "#080D19";
      selection_bg = "#164A43"; selection_fg = "#E9FFF8";
      normal = {
        black = "#142033"; red = "#FF6B87"; green = "#00F5C8"; yellow = "#F6DF82";
        blue = "#73B7FF"; magenta = "#FF24AE"; cyan = "#61E8FF"; white = "#CBDFE7";
      };
      bright = {
        black = "#65808F"; red = "#FF9CAE"; green = "#7AFFDE"; yellow = "#FFF0B3";
        blue = "#A5D1FF"; magenta = "#FF8DDB"; cyan = "#A3F3FF"; white = "#FFF3FC";
      };
    };
  };
  light = dark // {
    primary = "#007B65"; on_primary = "#F1FFFA";
    secondary = "#006B60"; on_secondary = "#F1FFFA";
    tertiary = "#006A80"; on_tertiary = "#F1FFFA";
    error = "#B7274B"; on_error = "#FFFFFF";
    surface = "#EDF9F5"; on_surface = "#102B2B";
    surface_container = "#DDEEE8"; on_surface_variant = "#405F5B";
    outline_variant = "#90B4AA"; shadow = "#A1C6BD";
    hover = "#BDEBDF"; on_hover = "#123E35";
    terminal = dark.terminal // {
      background = "#EDF9F5"; foreground = "#102B2B";
      cursor = "#007B65"; cursor_text = "#FFFFFF";
      selection_bg = "#B6DFD2"; selection_fg = "#102B2B";
      normal = {
        black = "#102B2B"; red = "#B7274B"; green = "#007B65"; yellow = "#806300";
        blue = "#1A5F9E"; magenta = "#A60064"; cyan = "#006A80"; white = "#405F5B";
      };
      bright = {
        black = "#58736D"; red = "#B7274B"; green = "#006C59"; yellow = "#795300";
        blue = "#004F92"; magenta = "#930059"; cyan = "#005D6E"; white = "#102B2B";
      };
    };
  };
  stripHash = pkgs.lib.removePrefix "#";
in {
  name = "OLO-Neon";
  inherit dark light neon;
  # Bar icon colours: neon, one per icon, never repeated (settings.nix assigns them; the
  # barIcons check measures them).  Every one reads at 4.5:1 or better even with the bar at
  # 60% opacity over a mid-grey wallpaper: the reds, pinks, blues and purples that fell short
  # were brightened within their own hue (2026-11-21).  Keep these apart from the OLO
  # control-fill palette.
  barAccents = {
    apricot = "#F2995A";
    brightVermilion = "#FF8142";
    darkOrange = "#FF8800";
    amber = "#FFB300";
    schoolBusYellow = "#F9DC05";
    neonYellowGreen = "#CCFF00";
    neonLime = "#7CFF2B";
    neonGreen = "#1EFF6E";
    aquamarine = "#00FFC8";
    electricBlue = "#00ECFF";
    brightDodgerBlue = "#4DA9FF";
    periwinkle = "#8A9FFF";
    brightViolet = "#AD94FF";
    brightPurple = "#D681FE";
    brightMagenta = "#FF63FC";
    brightHotPink = "#FF70CE";
    brightRose = "#F58099";
    candyPink = "#FF8ABB";
    # tints
    skyBlue = "#6BC5FF";
    peach = "#FFA07A";
    lemon = "#FFF57A";
    mint = "#9CFFD0";
    springBud = "#C4FF7A";
    lilac = "#E6A3FF";
    bubblegum = "#FF9AE0";
    coral = "#FF8A8A";
  };
  fontConfig = pkgs.writeText "olo-neon-fonts.conf" ''
    <?xml version="1.0"?>
    <!DOCTYPE fontconfig SYSTEM "fonts.dtd">
    <fontconfig>
      <include ignore_missing="yes">/etc/fonts/fonts.conf</include>
      <dir>${pkgs.inter}/share/fonts</dir>
      <dir>${pkgs.nerd-fonts.jetbrains-mono}/share/fonts</dir>
    </fontconfig>
  '';
  palette = pkgs.writeText "OLO-Neon.json" (builtins.toJSON { version = 2; inherit dark light; });
  greeterPalette = builtins.removeAttrs dark [ "terminal" "surface_container" "outline_variant" ] // {
    surface_variant = dark.surface_container;
    outline = dark.outline_variant;
  };
  wallpaper = pkgs.runCommand "olo-neon-wallpaper.png" { nativeBuildInputs = [ pkgs.librsvg ]; } ''
    rsvg-convert --width 3840 --height 2160 ${./theme/wallpaper.svg} --output $out
  '';
  terminalConfig = pkgs.writeText "olo-neon-foot.ini" (''
    [main]
    font=JetBrainsMono Nerd Font:size=11
    pad=18x18
    [colors-dark]
    alpha=0.96
    background=${stripHash dark.surface}
    foreground=${stripHash dark.on_surface}
    selection-background=${stripHash dark.terminal.selection_bg}
    selection-foreground=${stripHash dark.terminal.selection_fg}
  '' + pkgs.lib.concatImapStrings (i: name: ''
    regular${toString (i - 1)}=${stripHash dark.terminal.normal.${name}}
    bright${toString (i - 1)}=${stripHash dark.terminal.bright.${name}}
  '') [ "black" "red" "green" "yellow" "blue" "magenta" "cyan" "white" ]);
}
