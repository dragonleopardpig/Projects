{ theme }:
{
  session.default = "Noctalia Suite";
  appearance = {
    scheme = "Synced";
    theme_mode = "dark";
    font_family = "Inter";
    corner_radius_scale = 1.15;
    palette = theme.greeterPalette;
    wallpaper = { path = toString theme.wallpaper; fill_mode = "crop"; };
  };
  keyboard.layout = "us";
  cursor.size = 24;
}
