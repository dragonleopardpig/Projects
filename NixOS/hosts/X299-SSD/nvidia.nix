# NVIDIA driver for the portable X299-SSD image.
#
# Kept separate from hosts/X299/nvidia.nix because that one sets `open =
# false`, which cannot drive this machine: as of 2026-09-14 X299-SSD boots on
# an Acer Predator Helios Neo 16 AI whose dGPU is a GeForce RTX 5070 Ti Mobile
# (GB205, Blackwell), and Blackwell is supported *only* by NVIDIA's open kernel
# modules.  The closed module has no GB205 support at all.
#
# Why this is needed rather than leaving nouveau in place: the laptop's HDMI
# port is wired to the dGPU (card0-HDMI-A-1), the internal panel to the Intel
# iGPU (card1-eDP-1).  On nouveau this GB205 comes up with `GART: 0 MiB` and
# "MM: using COPY for buffer copies" -- no working aperture, no reclocking --
# so every 4K frame Hyprland renders on Intel has to be copied across to an
# unaccelerated GPU to be scanned out.  nouveau also exposes no i2c adapter on
# that connector, so DDC/CI (external monitor brightness) is unreachable.
#
# Universality note: this pins the image to Turing (2018) or newer NVIDIA
# hardware, since `open = true` covers only those.  On a machine with no NVIDIA
# GPU the module simply never binds and the blacklisting of nouveau is inert,
# so Intel/AMD-only hosts are unaffected.
{ config, lib, pkgs, ... }:
{
  hardware.graphics.enable = true;

  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.nvidia = {
    package = config.boot.kernelPackages.nvidiaPackages.stable;

    # Required for Wayland; sets nvidia-drm.modeset=1.
    modesetting.enable = true;

    # nvidia-suspend/resume/hibernate units, so the GPU tears down cleanly.
    powerManagement.enable = true;
    # Fine-grained runtime power-off needs PRIME offload, which is not set up
    # here (the dGPU owns a physical output, so it has to stay available).
    powerManagement.finegrained = false;

    # Mandatory on Blackwell -- see the header comment.
    open = true;

    nvidiaSettings = true;
  };

  # PRIME offload/sync are deliberately not configured: they need per-machine
  # PCI bus IDs, which would defeat the point of a portable image, and they are
  # X11 constructs.  Hyprland drives both GPUs natively on Wayland.
}
