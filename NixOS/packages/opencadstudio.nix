{
  lib,
  rustPlatform,
  fetchFromGitHub,
  makeWrapper,
  pkg-config,
  symlinkJoin,
  fontconfig,
  freetype,
  libGL,
  libxkbcommon,
  libx11,
  libxcursor,
  libxi,
  libxrandr,
  vulkan-loader,
  wayland,
}:

let
  buildLibraries = [
    fontconfig
    freetype
    libGL
    libxkbcommon
    libx11
    libxcursor
    libxi
    libxrandr
    wayland
  ];
  runtimeLibraries = buildLibraries ++ [ vulkan-loader ];

  unwrapped = rustPlatform.buildRustPackage rec {
    pname = "opencadstudio";
    version = "2026.37.0-1450fdee";

    src = fetchFromGitHub {
      owner = "dragonleopardpig";
      repo = "OpenCADStudio";
      rev = "1450fdeedff2c4bb094be06551512f270964122a";
      hash = "sha256-gg1AY1/nEHtAwAUoR5wzIGjSibFBHl8xxWZQv1uZCUo=";
    };

    cargoHash = "sha256-AgBWKRNpfB2CNs2EGTK03Y3wOFxh30uWJhXuoDUdSbo=";

    nativeBuildInputs = [ pkg-config ];

    buildInputs = buildLibraries;

    cargoBuildFlags = [ "--bin" "OpenCADStudio" ];
    cargoInstallFlags = cargoBuildFlags;

    # The upstream suite includes font-discovery and Windows-path assertions
    # that fail in Nix's isolated Linux build environment.
    doCheck = false;

    postInstall = ''
      install -Dm644 packaging/OpenCADStudio.desktop \
        $out/share/applications/io.github.HakanSeven12.OpenCadStudio.desktop
      install -Dm644 assets/logo.svg \
        $out/share/icons/hicolor/scalable/apps/io.github.HakanSeven12.OpenCadStudio.svg
      install -Dm644 packaging/io.github.HakanSeven12.OpenCadStudio.metainfo.xml \
        $out/share/metainfo/io.github.HakanSeven12.OpenCadStudio.metainfo.xml
    '';

    meta = {
      description = "2D and 3D CAD application for DWG and DXF drawings";
      homepage = "https://www.opencadstudio.com";
      license = lib.licenses.gpl3Plus;
      mainProgram = "OpenCADStudio";
      platforms = lib.platforms.linux;
    };
  };

in
symlinkJoin {
  name = "opencadstudio-${unwrapped.version}";
  paths = [ unwrapped ];
  nativeBuildInputs = [ makeWrapper ];

  postBuild = ''
    wrapProgram $out/bin/OpenCADStudio \
      --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath runtimeLibraries}"
  '';

  inherit (unwrapped) meta;
  passthru.unwrapped = unwrapped;
}
