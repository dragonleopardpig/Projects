{ lib
, stdenv
, python3
, qt6
, rclone
, fuse3
, xdg-utils
, coreutils
, fontconfig
, kitty
}:
let
  pythonEnv = python3.withPackages (ps: [ ps.pyqt6 ]);
in
stdenv.mkDerivation {
  pname = "rclone-control";
  version = "1.0.0";

  src = ./.;

  nativeBuildInputs = [ qt6.wrapQtAppsHook ];
  buildInputs = [ qt6.qtbase qt6.qtwayland ];

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    export QT_QPA_PLATFORM=offscreen
    export FONTCONFIG_FILE="${fontconfig.out}/etc/fonts/fonts.conf"
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME/.config/rclone"
    PATH="${lib.makeBinPath [ rclone coreutils ]}:$PATH" \
      ${pythonEnv}/bin/python3 -m unittest discover -s tests -v
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib/rclone-control $out/bin \
      $out/share/applications \
      $out/share/icons/hicolor/scalable/apps

    cp -r rclone_control $out/lib/rclone-control/

    cat > $out/bin/rclone-control <<EOF
    #!${pythonEnv}/bin/python3
    import os
    import sys

    sys.path.insert(0, "$out/lib/rclone-control")
    os.environ["PATH"] = "${lib.makeBinPath [ rclone fuse3 xdg-utils coreutils kitty ]}" + (
        ":" + os.environ["PATH"] if os.environ.get("PATH") else ""
    )

    from rclone_control.app import main
    sys.exit(main())
    EOF
    chmod +x $out/bin/rclone-control

    install -Dm444 assets/rclone-control.svg $out/share/icons/hicolor/scalable/apps/rclone-control.svg

    cat > $out/share/applications/rclone-control.desktop <<EOF
    [Desktop Entry]
    Type=Application
    Name=Rclone Control
    GenericName=Rclone Cloud Manager
    Comment=Full-control dual-pane explorer, transfer monitor, mount manager, and config editor for rclone
    Exec=$out/bin/rclone-control
    Icon=rclone-control
    Terminal=false
    Categories=Network;FileTransfer;Utility;
    StartupWMClass=rclone-control
    EOF

    wrapQtApp $out/bin/rclone-control

    runHook postInstall
  '';

  meta = {
    description = "Full-control Noctalia/OLO-Neon themed GUI for rclone remotes, transfers, mounts, and config";
    platforms = lib.platforms.linux;
    mainProgram = "rclone-control";
  };
}
