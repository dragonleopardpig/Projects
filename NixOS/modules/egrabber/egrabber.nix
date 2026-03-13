# Euresys Memento + eGrabber kernel drivers for CoaxLink/GrabLink PCIe frame grabber
{ config, lib, pkgs, ... }:

let
  kernelPackages = config.boot.kernelPackages;
  kdir = "${kernelPackages.kernel.dev}/lib/modules/${kernelPackages.kernel.modDirVersion}/build";
  modDir = kernelPackages.kernel.modDirVersion;

  patchDriverSource = ''
    find . -type f \( -name "*.c" -o -name "*.h" -o -name "Makefile*" -o -name "*.mk" \) -exec sed -i 's/\r$//' {} +
    sed -i 's|SHELL:=/bin/bash|SHELL:=${pkgs.bash}/bin/bash|' linux/Makefile
  '';

  # Build Memento kernel module first (eGrabber depends on it)
  mementoKmod = pkgs.stdenv.mkDerivation {
    pname = "memento-kmod";
    version = "26.02.0.8";
    src = ./memento-drivers;
    nativeBuildInputs = kernelPackages.kernel.moduleBuildDependencies;
    dontConfigure = true;
    patchPhase = patchDriverSource;
    buildPhase = ''
      runHook preBuild
      make -C linux KDIR=${kdir} MODULES="memento" -j$NIX_BUILD_CORES
      runHook postBuild
    '';
    installPhase = ''
      mkdir -p $out/lib/modules/${modDir}/extra
      cp linux/memento.ko $out/lib/modules/${modDir}/extra/
      # Export Module.symvers so eGrabber can link against it
      mkdir -p $out/drivers/linux
      cp linux/Module.symvers $out/drivers/linux/
    '';
    meta = {
      description = "Euresys Memento kernel module (tracing/diagnostics)";
      platforms = [ "x86_64-linux" ];
    };
  };

  # Build eGrabber kernel modules with Memento support
  egrabberKmod = pkgs.stdenv.mkDerivation {
    pname = "egrabber-kmod";
    version = "26.02.1.18";
    src = ./egrabber-drivers;
    nativeBuildInputs = kernelPackages.kernel.moduleBuildDependencies;
    dontConfigure = true;
    patchPhase = patchDriverSource;
    buildPhase = ''
      runHook preBuild
      make -C linux KDIR=${kdir} \
        MODULES="coaxlink grablink" \
        PATH_TO_MEMENTO_MODULE_SYMVERS=${mementoKmod}/drivers/linux/Module.symvers \
        -j$NIX_BUILD_CORES
      runHook postBuild
    '';
    installPhase = ''
      mkdir -p $out/lib/modules/${modDir}/extra
      cp linux/coaxlink.ko $out/lib/modules/${modDir}/extra/
      cp linux/grablink.ko $out/lib/modules/${modDir}/extra/
    '';
    meta = {
      description = "Euresys eGrabber kernel modules (CoaxLink/GrabLink) with Memento support";
      platforms = [ "x86_64-linux" ];
    };
  };

  # FHS environment for running vendor installers (Ubuntu/Debian-like)
  # Usage: run `euresys-fhs` to enter the environment, then run install scripts
  euresysFHS = pkgs.buildFHSEnv {
    name = "euresys-fhs";
    targetPkgs = pkgs: with pkgs; [
      # Build tools
      gcc
      gnumake
      binutils
      # Kernel headers
      kernelPackages.kernel.dev
      # Common libs vendor installers expect
      glibc
      zlib
      stdenv.cc.cc.lib
      libGL
      # Utilities
      bash
      coreutils
      findutils
      gnugrep
      gnused
      gawk
      which
      file
      pciutils
      kmod
      udev
      # GTK2 (Memento GUI and other vendor tools)
      gtk2
      glib
      cairo
      pango
      gdk-pixbuf
      atk
      libsm
      libice
      expat
      libGLU
      # X11
      libx11
      libxext
      libxrender
      libxi
      libxrandr
      libxcursor
      libxfixes
      libxft
      libxtst
      libxcomposite
      libxdamage
      libxinerama
      freetype
      fontconfig
      dbus
      # XCB / xkbcommon (needed by bundled Qt5 xcb plugin)
      libxcb
      libxkbcommon
      xorg.libxkbfile
      # Qt (for eGrabber Studio / GenTL tools)
      qt5.qtbase
      qt6.qtbase
      qt6.qtwayland
    ];
    runScript = "bash";
  };
in
{
  # Load kernel modules on boot: memento first, then eGrabber drivers
  boot.extraModulePackages = [ mementoKmod egrabberKmod ];
  boot.kernelModules = [ "memento" "coaxlink" "grablink" ];

  # Make the FHS environment available system-wide
  environment.systemPackages = [ euresysFHS ];

  # Persistent directories for vendor software installed via FHS env
  systemd.tmpfiles.rules = [
    "d /opt/euresys 0755 root root -"
    "d /lib/firmware/euresys 0755 root root -"
  ];

  # Create /dev nodes for Euresys drivers after modules load
  # The vendor uses modprobe.d install hooks; on NixOS we use a systemd service instead
  systemd.services.euresys-createdev = {
    description = "Create Euresys device nodes";
    after = [ "systemd-modules-load.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig.Type = "oneshot";
    serviceConfig.RemainAfterExit = true;
    script = ''
      create_devs() {
        driver=$1
        max=''${2:-15}
        major=$(${pkgs.gawk}/bin/awk -v d="$driver" '$2 == d {print $1}' /proc/devices)
        [ -z "$major" ] && return
        for i in $(${pkgs.coreutils}/bin/seq 0 $max); do
          ${pkgs.coreutils}/bin/mknod -m 666 /dev/$driver$i c $major $i 2>/dev/null || true
        done
      }
      create_devs memento
      create_devs coaxlink
      create_devs grablink
    '';
  };

  # Create qt.conf for eGrabber Studio so it finds its bundled Qt5 plugins
  system.activationScripts.euresysQtConf = ''
    for dir in /opt/euresys/egrabber*/studio; do
      if [ -d "$dir/plugins/platforms" ] && [ ! -f "$dir/qt.conf" ]; then
        cat > "$dir/qt.conf" << EOF
    [Paths]
    Plugins = plugins
    EOF
      fi
    done
  '';
}
