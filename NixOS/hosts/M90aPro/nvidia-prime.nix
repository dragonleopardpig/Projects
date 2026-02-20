# M90aPro NVIDIA Prime configuration (Laptop with Intel + NVIDIA)
{ config, lib, pkgs, ... }:

let
  # Convenient wrapper script for NVIDIA offload
  nvidia-offload = pkgs.writeShellScriptBin "nvidia-offload" ''
    export __NV_PRIME_RENDER_OFFLOAD=1
    export __NV_PRIME_RENDER_OFFLOAD_PROVIDER=NVIDIA-G0
    export __GLX_VENDOR_LIBRARY_NAME=nvidia
    export __VK_LAYER_NV_optimus=NVIDIA_only
    exec "$@"
  '';
in
{
  # Enable OpenGL
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  # Load nvidia driver for Xorg and Wayland
  services.xserver.videoDrivers = ["nvidia" "modesetting"];

  hardware.nvidia = {
    # Modesetting is required
    modesetting.enable = true;

    # Power management for laptops
    powerManagement = {
      enable = true;
      # finegrained = true; # Enable for Turing+ GPUs if you want aggressive power saving
    };

    # NVIDIA Prime configuration
    prime = {
      # Sync mode: Both GPUs always on, NVIDIA renders everything
      sync.enable = true;

      # Alternative: Offload mode (better battery, on-demand performance)
      # Comment sync.enable above and uncomment these to use offload mode:
      # offload = {
      #   enable = true;
      #   enableOffloadCmd = true; # Adds `nvidia-offload` command
      # };

      # IMPORTANT: Replace these with YOUR actual PCI bus IDs
      # Find them using: lspci | grep VGA
      intelBusId = "PCI:0:2:0";  # Intel integrated GPU
      nvidiaBusId = "PCI:2:0:0";  # NVIDIA discrete GPU
    };

    # Use open source kernel module (alpha quality, not recommended yet)
    open = false;

    # Enable NVIDIA settings menu
    nvidiaSettings = true;

    # Driver package
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };

  # Add the offload script to system packages (useful in offload mode)
  environment.systemPackages = [ nvidia-offload ];
}