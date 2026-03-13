{ config, lib, pkgs, ... }:

{
  home.packages = with pkgs; [
    gtk2
    pango
    cairo
    gdk-pixbuf
    atk
    at-spi2-atk
    at-spi2-core
    glib
    dbus
    dbus-glib
    nss
    nspr
    cups
    alsa-lib
    libxkbcommon
    libxcb
    libxkbfile
    fontconfig
    freetype
    libdrm
    mesa
    libxshmfence
    xorg.libX11
    xorg.libXext
    xorg.libXrender
    xorg.libXcomposite
    xorg.libXcursor
    xorg.libXi
    xorg.libXtst
    xorg.libXrandr
    xorg.libXScrnSaver
    xorg.libXdamage
    xorg.libXfixes
    expat
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-cjk-serif
    noto-fonts-color-emoji
  ];

  # EasyConnect .deb runner: extract to ~/.local/opt and run inside FHS env
  home.file.".local/bin/easyconnect-deb" = {
    executable = true;
    text = ''
      #!/bin/sh
      set -eu

      DEB_PATH="$HOME/Downloads/EasyConnect_x64_7_6_7_3.deb"
      APP_DIR="$HOME/.local/opt/easyconnect"
      SYSTEM_EC_DIR="/usr/share/sangfor/EasyConnect"
      ICON_DIR="$HOME/.local/share/icons/hicolor/256x256/apps"

      if [ ! -f "$DEB_PATH" ] && [ ! -d "$APP_DIR" ]; then
        echo "EasyConnect .deb not found at: $DEB_PATH"
        exit 1
      fi

      if [ -f "$DEB_PATH" ]; then
        mkdir -p "$APP_DIR"
        # If app.asar was previously extracted into a dir, dpkg -x will fail
        if [ -d "$APP_DIR/usr/share/sangfor/EasyConnect/resources/app.asar" ]; then
          rm -rf "$APP_DIR/usr/share/sangfor/EasyConnect/resources/app.asar"
        fi
        ${pkgs.dpkg}/bin/dpkg -x "$DEB_PATH" "$APP_DIR"
      fi

      # Prefer user install path so it is visible inside the FHS env
      EC_DIR="$APP_DIR/usr/share/sangfor/EasyConnect"
      EC_BIN="$EC_DIR/EasyConnect"
      EC_SH="$EC_DIR/resources/shell/EasyConnect.sh"
      EC_SH_PATCHED="$APP_DIR/EasyConnect.sh"
      if [ ! -f "$EC_BIN" ]; then
        echo "EasyConnect binary not found at: $EC_BIN"
        exit 1
      fi
      # Ensure legacy Web path exists (app expects /usr/share/sangfor/Web)
      if [ ! -e "$APP_DIR/usr/share/sangfor/Web" ] && [ -d "$EC_DIR/resources/Web" ]; then
        ln -s "$EC_DIR/resources/Web" "$APP_DIR/usr/share/sangfor/Web"
      fi

      # Ensure src/ exists on disk (some builds load modules outside asar)
      EC_SRC_DIR="$EC_DIR/src"
      EC_WEB_DIR="$EC_SRC_DIR/service/web"
      EC_JS_API="$EC_WEB_DIR/ec_js_api.js"
      if [ -f "$EC_DIR/resources/app.asar" ]; then
        mkdir -p "$EC_WEB_DIR"
        # Use a pinned Node for asar to avoid incompatibilities
        export PATH=${pkgs.nodejs_20}/bin:"$PATH"
        if [ ! -f "$EC_SRC_DIR/service/util/protocal.js" ]; then
          TMP_ASAR="$(mktemp -d)"
          ${pkgs.asar}/bin/asar extract "$EC_DIR/resources/app.asar" "$TMP_ASAR"
          if [ -d "$TMP_ASAR/src" ]; then
            cp -a "$TMP_ASAR/src/." "$EC_SRC_DIR/"
          fi
          rm -rf "$TMP_ASAR"
        fi
      fi
      if [ -w "$EC_BIN" ]; then
        chmod +x "$EC_BIN"
      fi
      if [ -f "$EC_SH" ] && [ -w "$EC_SH" ]; then
        chmod +x "$EC_SH"
      fi

      mkdir -p "$ICON_DIR"
      if [ ! -f "$ICON_DIR/EasyConnect.png" ] && [ -f "$APP_DIR/usr/share/pixmaps/EasyConnect.png" ]; then
        cp -f "$APP_DIR/usr/share/pixmaps/EasyConnect.png" "$ICON_DIR/EasyConnect.png"
      fi

      if [ -z "''${DISPLAY:-}" ]; then
        for sock in /tmp/.X11-unix/X*; do
          [ -S "$sock" ] || continue
          export DISPLAY=":''${sock##*X}"
          break
        done
      fi
      if [ -z "''${XAUTHORITY:-}" ] && [ -f "$HOME/.Xauthority" ]; then
        export XAUTHORITY="$HOME/.Xauthority"
      fi

      LOG="$HOME/.local/state/easyconnect.log"
      mkdir -p "$HOME/.local/state"
      : > "$LOG"
      echo "Starting EasyConnect at $(date)" >>"$LOG"
      EC_FONTS_DIR="$HOME/.local/share/easyconnect-fonts"
      if [ -f "$EC_FONTS_DIR/fonts.conf" ]; then
        export FONTCONFIG_FILE="$EC_FONTS_DIR/fonts.conf"
        export FONTCONFIG_PATH="$EC_FONTS_DIR"
      fi
      export QT_QPA_PLATFORM=xcb
      export XDG_SESSION_TYPE=x11
      export GDK_BACKEND=x11
      export WAYLAND_DISPLAY=
      export GTK2_RC_FILES=/dev/null
      export GTK_THEME=Raleigh
      export QTWEBENGINE_DISABLE_SANDBOX=1
      export ELECTRON_DISABLE_SANDBOX=1

      EC_PANGO_LIB="$EC_DIR/pango/usr/local/lib"
      if [ -d "$EC_PANGO_LIB" ]; then
        export LD_LIBRARY_PATH="$EC_PANGO_LIB:''${LD_LIBRARY_PATH:-}"
      fi

      # Ensure EasyMonitor is running (user session fallback)
      EC_MONITOR="$EC_DIR/resources/bin/EasyMonitor"
      if [ -x "$EC_MONITOR" ] && ! pgrep -x EasyMonitor >/dev/null 2>&1; then
        "$EC_MONITOR" >/dev/null 2>&1 &
      fi

      # Run the binary directly to avoid vendor script hardcoded /usr/share paths
      export ELECTRON_ENABLE_LOGGING=1
      export QT_DEBUG_PLUGINS=1
      # If Electron asks for an app path, point it to the extracted app.asar dir
      APP_PATH=""
      # Ensure app.asar is a file (Electron expects a file, not a directory)
      if [ -d "$EC_DIR/resources/app.asar" ] && [ -f "$EC_DIR/resources/app.asar.orig" ]; then
        rm -rf "$EC_DIR/resources/app.asar"
        mv "$EC_DIR/resources/app.asar.orig" "$EC_DIR/resources/app.asar"
      fi

      if [ -f "$EC_DIR/resources/app.asar" ]; then
        APP_PATH="$EC_DIR/resources/app.asar"
      elif [ -f "$EC_DIR/resources/default_app.asar" ]; then
        APP_PATH="$EC_DIR/resources/default_app.asar"
      fi

      EC_FLAGS="--no-sandbox --disable-setuid-sandbox --disable-gpu-sandbox --disable-namespace-sandbox --disable-seccomp-filter-sandbox --disable-seccomp-sandbox --no-zygote --enable-logging=stderr --v=1 --enable-transparent-visuals --disable-gpu --disable-dev-shm-usage --ozone-platform=x11 --disable-features=UseOzonePlatform"
      export PATH="/run/wrappers/bin:$PATH"

      if [ -n "$APP_PATH" ]; then
        if fhs -c "cd \"$EC_DIR\"; \"$EC_BIN\" \"$APP_PATH\" $EC_FLAGS" -- "$@" >>"$LOG" 2>&1; then
          exit 0
        fi
      else
        if fhs -c "cd \"$EC_DIR\"; \"$EC_BIN\" $EC_FLAGS" -- "$@" >>"$LOG" 2>&1; then
          exit 0
        fi
      fi

      # Fallback when user namespaces are disabled (bwrap fails).
      export NIX_LD=${pkgs.glibc}/lib/ld-linux-x86-64.so.2
      EC_LIBS="${pkgs.gtk2}/lib:${pkgs.gdk-pixbuf}/lib:${pkgs.atk}/lib:${pkgs.at-spi2-atk}/lib:${pkgs.at-spi2-core}/lib:${pkgs.glib.out}/lib:${pkgs.pango.out}/lib:${pkgs.cairo}/lib:${pkgs.fontconfig.lib}/lib:${pkgs.freetype}/lib:${pkgs.dbus.lib}/lib:${pkgs.dbus-glib}/lib:${pkgs.nss}/lib:${pkgs.nspr}/lib:${pkgs.cups.lib}/lib:${pkgs.alsa-lib}/lib:${pkgs.libxkbcommon}/lib:${pkgs.libxcb}/lib:${pkgs.libxkbfile}/lib:${pkgs.libdrm}/lib:${pkgs.mesa}/lib:${pkgs.libxshmfence}/lib:${pkgs.xorg.libX11}/lib:${pkgs.xorg.libXext}/lib:${pkgs.xorg.libXrender}/lib:${pkgs.xorg.libXcomposite}/lib:${pkgs.xorg.libXcursor}/lib:${pkgs.xorg.libXi}/lib:${pkgs.xorg.libXtst}/lib:${pkgs.xorg.libXrandr}/lib:${pkgs.xorg.libXScrnSaver}/lib:${pkgs.xorg.libXdamage}/lib:${pkgs.xorg.libXfixes}/lib:${pkgs.expat}/lib:${pkgs.stdenv.cc.cc.lib}/lib"
      export NIX_LD_LIBRARY_PATH="$EC_LIBS:/run/current-system/sw/lib:/run/current-system/sw/lib64:/etc/profiles/per-user/$USER/lib:$HOME/.nix-profile/lib:''${NIX_LD_LIBRARY_PATH:-}"
      export LD_LIBRARY_PATH="$EC_LIBS:/run/current-system/sw/lib:/run/current-system/sw/lib64:/etc/profiles/per-user/$USER/lib:$HOME/.nix-profile/lib:''${LD_LIBRARY_PATH:-}"

      if [ -n "$APP_PATH" ]; then
        exec "$EC_BIN" "$APP_PATH" $EC_FLAGS >>"$LOG" 2>&1
      else
        exec "$EC_BIN" $EC_FLAGS >>"$LOG" 2>&1
      fi
    '';
  };

  home.file.".local/share/easyconnect-fonts/fonts.conf" = {
    text = ''
      <?xml version="1.0"?>
      <!DOCTYPE fontconfig SYSTEM "fonts.dtd">
      <fontconfig>
        <include ignore_missing="yes">/etc/fonts/fonts.conf</include>
        <dir>~/.local/share/fonts</dir>
        <dir>/etc/profiles/per-user/thinky/share/fonts</dir>
        <dir>/run/current-system/sw/share/fonts</dir>
        <dir>/run/current-system/sw/share/X11/fonts</dir>
        <dir>/usr/share/fonts</dir>

        <alias>
          <family>Microsoft YaHei</family>
          <prefer>
            <family>WenQuanYi Micro Hei</family>
            <family>Noto Sans CJK SC</family>
          </prefer>
        </alias>
        <alias>
          <family>SimHei</family>
          <prefer>
            <family>WenQuanYi Micro Hei</family>
            <family>Noto Sans CJK SC</family>
          </prefer>
        </alias>
        <alias>
          <family>sans-serif</family>
          <prefer>
            <family>Noto Sans CJK SC</family>
            <family>WenQuanYi Micro Hei</family>
            <family>Noto Sans CJK TC</family>
            <family>Noto Sans CJK JP</family>
            <family>DejaVu Sans</family>
          </prefer>
        </alias>
      </fontconfig>
    '';
  };

  xdg.desktopEntries.easyconnect-deb = {
    name = "EasyConnect";
    exec = "/home/thinky/.local/bin/easyconnect-deb";
    icon = "/home/thinky/.local/share/icons/hicolor/256x256/apps/EasyConnect.png";
    comment = "Sangfor EasyConnect via FHS environment";
    categories = [ "Network" ];
    terminal = false;
  };

  # Build bundled Pango (1.43.0) for EasyConnect, matching Arch AUR workaround
  home.file.".local/bin/easyconnect-pango" = {
    executable = true;
    text = ''
      #!/bin/sh
      set -eu

      VERSION="1.43.0"
      TARBALL="pango-$VERSION.tar.xz"
      URL="https://download.gnome.org/sources/pango/1.43/$TARBALL"
      WORK="''${XDG_CACHE_HOME:-$HOME/.cache}/easyconnect-pango"
      if [ -d "/usr/share/sangfor/EasyConnect" ]; then
        EC_DIR="/usr/share/sangfor/EasyConnect"
      else
        EC_DIR="$HOME/.local/opt/easyconnect/usr/share/sangfor/EasyConnect"
      fi
      DEST="$EC_DIR/pango"

      if [ ! -d "$EC_DIR" ]; then
        echo "EasyConnect not installed at $EC_DIR"
        exit 1
      fi

      mkdir -p "$WORK"
      cd "$WORK"
      [ -f "$TARBALL" ] || curl -L -o "$TARBALL" "$URL"
      rm -rf "pango-$VERSION"
      tar xf "$TARBALL"

      cd "pango-$VERSION"
      PKG_CONFIG_PATH=""
      add_pc() {
        if [ -d "$1/lib/pkgconfig" ]; then
          PKG_CONFIG_PATH="$1/lib/pkgconfig:''${PKG_CONFIG_PATH}"
        fi
        if [ -d "$1/share/pkgconfig" ]; then
          PKG_CONFIG_PATH="$1/share/pkgconfig:''${PKG_CONFIG_PATH}"
        fi
      }
      add_pc "$(nix eval --raw nixpkgs#glib.dev)"
      add_pc "$(nix eval --raw nixpkgs#gobject-introspection.dev)"
      add_pc "$(nix eval --raw nixpkgs#cairo.dev)"
      add_pc "$(nix eval --raw nixpkgs#harfbuzz.dev)"
      add_pc "$(nix eval --raw nixpkgs#freetype.dev)"
      add_pc "$(nix eval --raw nixpkgs#fontconfig.dev)"
      add_pc "$(nix eval --raw nixpkgs#fribidi.dev)"
      add_pc "$(nix eval --raw nixpkgs#libthai.dev)"
      add_pc "$(nix eval --raw nixpkgs#libXft.dev)"
      add_pc "$(nix eval --raw nixpkgs#libX11.dev)"
      add_pc "$(nix eval --raw nixpkgs#libXrender.dev)"
      add_pc "$(nix eval --raw nixpkgs#pcre2.dev)"
      add_pc "$(nix eval --raw nixpkgs#libpng.dev)"
      add_pc "$(nix eval --raw nixpkgs#zlib.dev)"
      export PKG_CONFIG_PATH

      GLIB_GIR="$(nix eval --raw nixpkgs#glib.dev)/share/gir-1.0"
      export GI_GIR_PATH="$GLIB_GIR:''${GI_GIR_PATH:-}"

      nix shell \
        nixpkgs#gcc \
        nixpkgs#meson \
        nixpkgs#ninja \
        nixpkgs#pkg-config \
        nixpkgs#gobject-introspection \
        nixpkgs#gobject-introspection.dev \
        nixpkgs#glib.dev \
        nixpkgs#cairo.dev \
        nixpkgs#harfbuzz.dev \
        nixpkgs#freetype.dev \
        nixpkgs#fontconfig.dev \
        nixpkgs#fribidi.dev \
        nixpkgs#libthai.dev \
        nixpkgs#libXft.dev \
        nixpkgs#libX11.dev \
        nixpkgs#libXrender.dev \
        nixpkgs#pcre2.dev \
        nixpkgs#libpng.dev \
        nixpkgs#zlib.dev \
        nixpkgs#python3 \
        -c bash -c "meson . build -Dwrap_mode=nodownload && ninja -C build && DESTDIR=\"$DEST\" ninja -C build install"

      echo "Installed Pango to $DEST"
    '';
  };

  # Optional one-time setup for setuid helpers and EasyMonitor systemd service
  home.file.".local/bin/easyconnect-setup" = {
    executable = true;
    text = ''
      #!/bin/sh
      set -eu

      EC_DIR="$HOME/.local/opt/easyconnect/usr/share/sangfor/EasyConnect"
      RES_DIR="$EC_DIR/resources"
      if [ ! -d "$RES_DIR" ]; then
        echo "EasyConnect not installed at $EC_DIR"
        exit 1
      fi

      sudo chmod +x "$EC_DIR/EasyConnect" || true
      sudo mkdir -p "$RES_DIR/logs"
      sudo chmod 755 "$RES_DIR/logs"
      sudo chmod 755 "$RES_DIR/conf" -R
      sudo chmod +x "$RES_DIR/shell/"* || true

      for bin in ECAgent svpnservice CSClient; do
        if [ -f "$RES_DIR/bin/$bin" ]; then
          sudo chown root:root "$RES_DIR/bin/$bin"
          sudo chmod +s "$RES_DIR/bin/$bin"
        fi
      done

      if [ -x "$RES_DIR/bin/ECAgent" ]; then
        sudo "$RES_DIR/bin/ECAgent" --install-import-cert >/dev/null 2>&1 || true
      fi

      sudo systemctl enable --now EasyMonitor
    '';
  };

}
