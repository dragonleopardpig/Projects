{ pkgs, ... }:

{
  languages.rust = {
    enable = true;
    toolchainFile = ./rust-toolchain.toml;
  };

  env.packages = with pkgs; [
    rust-analyzer
    cargo-binstall
    rust-script
    gcc                        # Linker for Rust builds
    pkg-config
    openssl
    wayland
    glib
    atk
    cairo
    pango
    gdk-pixbuf
    gtk3
    libsoup_3
    webkitgtk_4_1
    enchant
    enchant2
  ];

  enterShell = ''
    # Install wasm-bindgen-cli if missing
    if ! command -v wasm-bindgen >/dev/null || \
       ! wasm-bindgen --version | grep -q "0.2.106"; then
      cargo binstall --force --version 0.2.106 wasm-bindgen-cli
    fi

    # Install Dioxus CLI
    if ! command -v dx >/dev/null; then
      cargo binstall --force dioxus-cli
    fi
  '';
}
