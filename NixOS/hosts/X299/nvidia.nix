{ config, pkgs, ... }:
{
 # Enable OpenGL
  hardware.graphics = {
    enable = true;
  };

  # CUDA toolkit
  environment.systemPackages = [ pkgs.cudaPackages.cudatoolkit ];

  # Stable symlink to CUDA headers for clangd / IDE integration
  system.activationScripts.cudaSymlink = ''
    cuda_path=$(${pkgs.coreutils}/bin/realpath ${pkgs.cudaPackages.cudatoolkit} 2>/dev/null)
    if [ -d "$cuda_path/include" ]; then
      ln -sfn "$cuda_path" /home/thinky/.local/share/cuda
    fi
  '';

  # Load nvidia driver for Xorg and Wayland
  services.xserver.videoDrivers = ["nvidia"];

  hardware.nvidia = {
    # Optionally, you may need to select the appropriate driver version for your specific GPU.
    package = config.boot.kernelPackages.nvidiaPackages.stable;

    # Modesetting is required.
    modesetting.enable = true;

    # Power management enables nvidia-suspend/resume/hibernate systemd services
    # which ensure proper GPU teardown on shutdown (prevents hang on power-off).
    powerManagement.enable = true;
    # Fine-grained power management. Only for laptops with Turing+ GPUs.
    powerManagement.finegrained = false;

    # Use the NVidia open source kernel module (not to be confused with the
    # independent third-party "nouveau" open source driver).
    # Support is limited to the Turing and later architectures. Full list of
    # supported GPUs is at:
    # https://github.com/NVIDIA/open-gpu-kernel-modules#compatible-gpus
    # Only available from driver 515.43.04+
    # Currently alpha-quality/buggy, so false is currently the recommended setting.
    open = false;

    # Enable the Nvidia settings menu,
	# accessible via `nvidia-settings`.
    nvidiaSettings = true;

  };
}
