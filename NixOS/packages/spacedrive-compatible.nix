{ symlinkJoin, spacedrive, makeWrapper }:

symlinkJoin {
  name = "spacedrive-compatible-${spacedrive.version}";
  paths = [ spacedrive ];
  nativeBuildInputs = [ makeWrapper ];
  # WebKitGTK's Wayland buffer path can disconnect the legacy desktop client
  # from the compositor. Keep this compatibility setting specific to Spacedrive.
  postBuild = ''
    wrapProgram "$out/bin/spacedrive" \
      --set GDK_BACKEND x11 \
      --set WEBKIT_DISABLE_DMABUF_RENDERER 1
  '';
  meta = spacedrive.meta;
}
