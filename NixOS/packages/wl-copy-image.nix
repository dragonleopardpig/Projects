{
  stdenv,
  pkg-config,
  gtk3,
  wayland,
  wayland-protocols,
  wayland-scanner,
}:

stdenv.mkDerivation {
  name = "wl-copy-image";
  nativeBuildInputs = [ pkg-config wayland-scanner ];
  buildInputs = [ gtk3 wayland ];
  dontUnpack = true;
  buildPhase = ''
    protocol=${wayland-protocols}/share/wayland-protocols/staging/ext-data-control/ext-data-control-v1.xml
    wayland-scanner client-header "$protocol" ext-data-control-v1-client-protocol.h
    wayland-scanner private-code "$protocol" ext-data-control-v1-protocol.c
    $CC -O2 -I. ${./wl-copy-image.c} ext-data-control-v1-protocol.c \
      $(pkg-config --cflags --libs gtk+-3.0 wayland-client) -o wl-copy-image
  '';
  installPhase = ''
    mkdir -p $out/bin
    cp wl-copy-image $out/bin/
  '';
}
