{ lib, stdenvNoCC, fetchFromGitHub, xcursorgen, adwaita-icon-theme }:

stdenvNoCC.mkDerivation {
  pname = "hyprland-logo-cursor";
  version = "0-unstable-2025-04-16";

  src = fetchFromGitHub {
    owner = "hyprcow";
    repo = "hyprland_theme";
    rev = "9529c54699f01e9fb0e636e4650246d3ae0f1043";
    hash = "sha256-ZqMR/2YPax5n9FycxSXeg5InkSszA++HvOodmwKwyDk=";
  };

  nativeBuildInputs = [ xcursorgen ];
  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    xcursorgen hyprland_logo_cursor.conf hyprland_logo
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    cursor_dir="$out/share/icons/Hyprland-Logo/cursors"
    mkdir -p "$cursor_dir"
    # Preserve text, resize, and other semantic shapes from the existing theme.
    ln -s ${adwaita-icon-theme}/share/icons/Adwaita/cursors/* "$cursor_dir/"
    install -m444 hyprland_logo "$cursor_dir/hyprland_logo"
    for name in default left_ptr arrow top_left_arrow; do
      ln -sfn hyprland_logo "$cursor_dir/$name"
    done
    cat > "$out/share/icons/Hyprland-Logo/index.theme" <<EOF
    [Icon Theme]
    Name=Hyprland Logo
    Comment=Hyprland's blue logo pointer with Adwaita text and resize cursors
    EOF
    install -Dm444 LICENSE "$out/share/licenses/hyprland-logo-cursor/LICENSE"
    runHook postInstall
  '';

  meta = {
    description = "Hyprland's built-in blue logo pointer as an Xcursor theme";
    homepage = "https://github.com/hyprcow/hyprland_theme";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
