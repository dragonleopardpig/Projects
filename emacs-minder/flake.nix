{
  description = "Emacs Minder — native Cairo/Pango/librsvg Rust dynamic module for Emacs 31";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/b1b875982b17dabde9b4a37f3e229e74913e6db3";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in {
      devShells.${system}.default = pkgs.mkShell {
        nativeBuildInputs = with pkgs; [
          rustc
          cargo
          gcc
          pkg-config
          emacs-pgtk
        ];
        buildInputs = with pkgs; [
          cairo
          pango
          librsvg
          gdk-pixbuf
          glib
        ];
      };

      packages.${system}.default = pkgs.rustPlatform.buildRustPackage {
        pname = "emacs-minder";
        version = "0.1.0";
        src = ./.;

        cargoLock.lockFile = ./Cargo.lock;

        nativeBuildInputs = with pkgs; [
          pkg-config
        ];

        nativeCheckInputs = with pkgs; [
          fontconfig
          dejavu_fonts
        ];

        FONTCONFIG_FILE = pkgs.makeFontsConf {
          fontDirectories = [ pkgs.dejavu_fonts ];
        };

        buildInputs = with pkgs; [
          cairo
          pango
          librsvg
          gdk-pixbuf
          glib
        ];

        installPhase = ''
          runHook preInstall
          mkdir -p $out/lib $out/share/emacs/site-lisp/emacs-minder
          cp target/*/release/libemacs_minder.so $out/lib/ 2>/dev/null || cp target/release/libemacs_minder.so $out/lib/
          cp lisp/emacs-minder.el $out/share/emacs/site-lisp/emacs-minder/
          runHook postInstall
        '';

        meta = with pkgs.lib; {
          description = "Native Emacs 31 dynamic module for Minder mind maps using Cairo/Pango/librsvg";
          license = licenses.gpl3Plus;
          platforms = platforms.linux;
        };
      };
    };
}
