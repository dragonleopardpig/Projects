{ pkgs, lib, config, inputs, ... }:

{
  packages = with pkgs; [
    claude-code
    # Rust toolchain
    rustc
    cargo
    rustfmt
    clippy
    rust-analyzer
    
    # Build dependencies
    pkg-config
    openssl
    sqlite
    gcc
    gnumake
    
    # File chooser dialog
    zenity
    
    # xdotool library (required by some dependencies)
    xdotool
    
    # XDG Desktop Portal for file dialogs
    xdg-desktop-portal
    xdg-desktop-portal-gtk
    
    # GTK and GLib dependencies (required for file dialogs)
    glib
    glib.dev
    gtk3
    gtk3.dev
    gtk4
    gtk4.dev
    cairo
    cairo.dev
    pango
    pango.dev
    gdk-pixbuf
    gdk-pixbuf.dev
    atk
    atk.dev
    
    # Wayland dependencies for Dioxus desktop
    wayland
    wayland.dev
    wayland-protocols
    libxkbcommon
    libxkbcommon.dev
    
    # Additional libraries for GUI
    libGL
    libGL.dev
    vulkan-loader
    xorg.libX11
    xorg.libX11.dev
    xorg.libXcursor
    xorg.libXi
    xorg.libXrandr
    xorg.libXtst
    libsoup_3
    libsoup_3.dev
    webkitgtk_4_1
    webkitgtk_4_1.dev
  ];

  env = {
    # Force GDK to use X11 backend (works better with WebView on Wayland)
    GDK_BACKEND = "x11";
    
    # Required for Wayland applications
    WAYLAND_DISPLAY = "wayland-1";
    XDG_RUNTIME_DIR = "/run/user/1000";
    
    # Enable XWayland
    DISPLAY = ":0";
    
    # WebKit/Graphics rendering fixes
    WEBKIT_DISABLE_COMPOSITING_MODE = "1";
    
    # PKG_CONFIG_PATH for finding libraries
    PKG_CONFIG_PATH = lib.makeSearchPath "lib/pkgconfig" (with pkgs; [
      glib.dev
      gtk3.dev
      gtk4.dev
      cairo.dev
      pango.dev
      gdk-pixbuf.dev
      atk.dev
      wayland.dev
      libxkbcommon.dev
      libGL.dev
      xorg.libX11.dev
      libsoup_3.dev
      webkitgtk_4_1.dev
    ]);
    
    # Vulkan and graphics + eGrabber vendor libs
    LD_LIBRARY_PATH = "/run/current-system/sw/share/nix-ld/lib:/opt/euresys/egrabber/lib/x86_64:" + lib.makeLibraryPath (with pkgs; [
      wayland
      libxkbcommon
      libGL
      vulkan-loader
      xorg.libX11
      xorg.libXcursor
      xorg.libXi
      xorg.libXrandr
      xorg.libXtst
      xdotool
      glib
      gtk3
      gtk4
      cairo
      pango
      gdk-pixbuf
      atk
      libsoup_3
      webkitgtk_4_1
      gcc.cc.lib
      stdenv.cc.cc.lib
    ]);
    
    # Compiler flags
    LIBRARY_PATH = lib.makeLibraryPath (with pkgs; [
      glib
      gtk3
      gtk4
      cairo
      pango
      gdk-pixbuf
      atk
      wayland
      libxkbcommon
      libGL
      xorg.libX11
      xorg.libXtst
      xdotool
      libsoup_3
      webkitgtk_4_1
      gcc.cc.lib
      stdenv.cc.cc.lib
    ]);
    
    # GTK/GLib configuration
    GIO_MODULE_DIR = "${pkgs.glib-networking}/lib/gio/modules";
    GSETTINGS_SCHEMA_DIR = "${pkgs.gtk3}/share/gsettings-schemas/${pkgs.gtk3.name}/glib-2.0/schemas";
  };

  enterShell = ''
    echo "Dioxus edge detection environment loaded"
    echo "Rust version: $(rustc --version)"
    echo "Cargo version: $(cargo --version)"
    echo ""
    echo "Run: cargo run"

    # Generate .clangd for egrab-capture so clangd finds gcc system headers
    # (Nix store paths change per host/generation, so we regenerate each time)
    # Only extract gcc/g++ and glibc includes (filter out all the -dev wrapper paths)
    _gcc_includes=$(g++ -xc++ -E -v /dev/null 2>&1 \
      | sed -n '/#include <\.\.\.>/,/End of search list/p' \
      | grep '^ ' \
      | sed 's/^ *//' \
      | grep -E '(gcc|glibc|c\+\+)')
    _clangd_file="egrab-capture/.clangd"
    {
      echo "CompileFlags:"
      echo "  Add:"
      echo "    - -I/opt/euresys/egrabber/include"
      for _inc in $_gcc_includes; do
        echo "    - -isystem$_inc"
      done
    } > "$_clangd_file"
  '';
}
