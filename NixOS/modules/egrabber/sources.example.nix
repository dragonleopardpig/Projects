# Copy this file to modules/egrabber/sources.nix and adjust the paths.
# Keep sources.nix out of git: it points at vendor-provided proprietary code.
{
  hardware.euresys.egrabberDriversSrc = /home/thinky/Downloads/egrabber-linux-x86_64-26.02.1.18/drivers;
  hardware.euresys.mementoDriversSrc = /home/thinky/Downloads/memento-linux-x86_64-26.02.0.8/drivers;
}
