# /etc/nixos/configuration.nix

{ inputs, lib, config,  pkgs, ... }:

{
  imports = [];

  # Disable swap
  swapDevices = lib.mkForce [ ];

  boot = {
    kernelPackages = pkgs.linuxPackages_latest;
    # kernelPackages = pkgs.linuxPackages_6_12;
    kernelModules = ["i2c-dev" "ddcci_backlight"];
    initrd.kernelModules = ["nvidia"];
    extraModulePackages = [
      config.boot.kernelPackages.nvidia_x11
      config.boot.kernelPackages.ddcci-driver
    ];
    kernelParams = [
      "quiet"
      "splash"
      "intremap=on"
      "boot.shell_on_fail"
      "udev.log_priority=3"
      "rd.systemd.show_status=auto"
      "systemd.swap=0"
    ];
    # silence first boot output
    consoleLogLevel = 3;
    initrd.verbose = false;
    initrd.systemd.enable = true;

    # plymouth, showing after LUKS unlock
    plymouth.enable = true;
    plymouth.font = "${pkgs.hack-font}/share/fonts/truetype/Hack-Regular.ttf";
    plymouth.logo = "${./assets/nix-snowflake-rainbow.png}";
  };

    # Boot console mode
  boot.loader = {
    systemd-boot.consoleMode = "max";
    systemd-boot.enable = false;
    grub.enable = true;
    grub.device = "nodev";
    grub.useOSProber = true;
    grub.efiSupport = true;
    efi.canTouchEfiVariables = true;
    efi.efiSysMountPoint = "/boot";
    grub2-theme = {
      enable = true;
      theme = "stylish";
      footer = true;
    };
  };

  services.udev.extraRules = ''
        KERNEL=="i2c-[0-9]*", GROUP="i2c", MODE="0660"
  '';

  # Console font configuration
  console.font = "${pkgs.terminus_font}/share/consolefonts/ter-i20n.psf.gz";
  console.packages = with pkgs; [ terminus_font ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.settings.trusted-users = [ "root" "thinky" ];
  nix.settings.download-buffer-size = 134217728; # 128 MB
  nix.gc = {
    automatic = true;
    dates = "daily";
    options = "--delete-older-than 7d";
  };

  hardware.i2c.enable = true;

  # GVFS for Nemo trash, network mounts, etc.
  services.gvfs.enable = true;

  # Create ddcci backlight device for external monitor brightness control
  # Auto-detects all i2c adapters (works with any GPU: NVIDIA, Intel, AMD)
  systemd.services.ddcci-setup = {
    description = "Setup ddcci backlight devices for external monitors";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-modules-load.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStartPre = "${pkgs.coreutils}/bin/sleep 5";
      ExecStart = pkgs.writeShellScript "ddcci-setup" ''
        for bus in /sys/bus/i2c/devices/i2c-*/; do
          busnum=$(basename "$bus")
          busnum=''${busnum#i2c-}
          # Only create ddcci device if a DDC/CI-capable monitor actually responds
          if ${pkgs.ddcutil}/bin/ddcutil --bus "$busnum" detect 2>/dev/null | grep -q "Display"; then
            echo "ddcci 0x37" > "$bus/new_device" 2>/dev/null || true
          fi
        done
      '';
    };
  };

  # Enable networking
  networking.networkmanager.enable = true;

  # Set your time zone.
  time.timeZone = "Asia/Singapore";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_SG.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_SG.UTF-8";
    LC_IDENTIFICATION = "en_SG.UTF-8";
    LC_MEASUREMENT = "en_SG.UTF-8";
    LC_MONETARY = "en_SG.UTF-8";
    LC_NAME = "en_SG.UTF-8";
    LC_NUMERIC = "en_SG.UTF-8";
    LC_PAPER = "en_SG.UTF-8";
    LC_TELEPHONE = "en_SG.UTF-8";
    LC_TIME = "en_SG.UTF-8";
  };

  # Enable the X11 windowing system.
  services.xserver = {
    enable = true;
    xkb.layout = "us";
    xkb.variant = "";
  };

  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
    package = pkgs.kdePackages.sddm;
    extraPackages = with pkgs; [
      kdePackages.qtsvg
      kdePackages.qtmultimedia
      kdePackages.qtvirtualkeyboard
    ];
    theme = "sddm-astronaut-theme";
    settings = {
      General = {
        DefaultSession = "hyprland-uwsm.desktop";
      };
      Theme = {
        Current = "sddm-astronaut-theme";
      };
    };
  };

  programs.uwsm = {
    enable = true;
    waylandCompositors = {
      hyprland = {
        prettyName = "Hyprland";
        comment = "Hyprland compositor managed by UWSM";
        binPath = "/run/current-system/sw/bin/start-hyprland";
      };
    };
  };

  programs.hyprland = {
    enable = true;
    withUWSM = true; # recommended for most users
    xwayland.enable = true; # Xwayland can be disabled.
    # set the flake package
    package = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.hyprland;
    # make sure to also set the portal package, so that they are in sync
    portalPackage = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.xdg-desktop-portal-hyprland;

  };

  programs.dconf.enable = true;

  # Enable CUPS to print documents.
  services.printing.enable = true;

  # Enable sound with pipewire.
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  systemd.user.services.orca.enable = false;

  services.upower.enable = true;
  services.gnome.gnome-keyring.enable = true;

  security.sudo = {
    enable = true;
    extraRules = [
      {
        users = [ "thinky" ];
        commands = [
          {
            command = "ALL"; # Allows all commands
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];
  };

  # Define a user account. Don't forget to set a password with 'passwd'.
  users.users.thinky = {
    isNormalUser = true;
    description = "thinky";
    extraGroups = [ "networkmanager" "wheel" "i2c"];
    subGidRanges = [
      {
        count = 65536;
        startGid = 1000;
      }
    ];
    subUidRanges = [
      {
        count = 65536;
        startUid = 1000;
      }
    ];
    packages = with pkgs; [
      #  thunderbird
    ];
  };

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    # archives
    zip
    xz
    unzip
    p7zip

    # utils
    yq-go # yaml processor https://github.com/mikefarah/yq

    # networking tools
    mtr # A network diagnostic tool
    iperf3
    dnsutils  # `dig` + `nslookup`
    ldns # replacement of `dig`, it provide the command `drill`
    aria2 # A lightweight multi-protocol & multi-source command-line download utility
    socat # replacement of openbsd-netcat
    nmap # A utility for network discovery and security auditing
    ipcalc  # it is a calculator for the IPv4/v6 addresses

    # misc
    cowsay
    file
    which
    tree
    gnused
    gnutar
    gawk
    zstd
    gnupg

    # nix related
    #
    # it provides the command `nom` works just like `nix`
    # with more details log output
    nix-output-monitor

    # productivity
    hugo # static site generator
    glow # markdown previewer in terminal

    iotop # io monitoring
    iftop # network monitoring

    # system call monitoring
    strace # system call monitoring
    ltrace # library call monitoring
    lsof # list open files

    # system tools
    sysstat
    lm_sensors # for `sensors` command
    ethtool
    pciutils # lspci
    usbutils # lsusb
    wget
    remmina
    protonvpn-gui
    inetutils
    lshw
    gparted
    usbimager
    sassc
    redshift
    gpustat
    hyprpaper
    swww
    hyprsunset
    hyprsysteminfo
    waypaper
    satty
    slurp
    grim
    xdg-desktop-portal
    xdg-desktop-portal-hyprland
    xdg-desktop-portal-gtk

    # themes
    variety
    orchis-theme
    tela-icon-theme
    tela-circle-icon-theme
    fluent-icon-theme
    adwaita-icon-theme
    (pkgs.sddm-astronaut.override {
      embeddedTheme = "pixel_sakura";
      themeConfig = {
        FormPosition = "left";
      };
    })

    # others
    git-credential-manager # type "unset SSH_ASKPASS" in command prompt
    brightnessctl
    ddcutil
    wl-clipboard
    upower
    networkmanager
    power-profiles-daemon
    texliveFull
    onlyoffice-desktopeditors
    librecad
    freecad
    gimp
    inkscape
    pinta
    mission-center
    resources
    filezilla
    traceroute
    imagemagick
    ffmpeg
    fim
    sxiv
    tiv
    chafa
    viu
    distrobox
    wofi
    walker
    nemo-with-extensions
    hyprpolkitagent
    libnotify
    jsonrpc-glib
    devenv
    claude-code
    claude-monitor
    ((emacsPackagesFor emacs-pgtk).emacsWithPackages (
      epkgs: with epkgs; [
        vterm
        direnv
        lsp-pyright
        zmq
      ]
    ))
    aspell
    aspellDicts.en
    aspellDicts.en-science
    aspellDicts.en-computers
    nodejs
    yaml-language-server
    vscode-json-languageserver
    typescript-language-server
    bash-language-server
    systemd-language-server
    nginx-language-server
    kotlin-language-server
    perlnavigator
    nixd
    nix-index
    marksman
    gcc
    enchant
    pkg-config
    libxml2
    glib
    enchant_2
    hunspell
    hunspellDicts.en_US
    nodejs_24
    spacedrive
    # sioyek wrapped to use XWayland (native Wayland has issues with NVIDIA)
    (pkgs.symlinkJoin {
      name = "sioyek-wrapped";
      paths = [ pkgs.sioyek ];
      buildInputs = [ pkgs.makeWrapper ];
      postBuild = ''
        wrapProgram $out/bin/sioyek --set QT_QPA_PLATFORM xcb
      '';
    })

    # Create an FHS environment using the command `fhs`,
    #enabling the execution of non-NixOS packages in NixOS!
    (let base = pkgs.appimageTools.defaultFhsEnvArgs; in
     pkgs.buildFHSEnv (base // {
       name = "fhs";
       targetPkgs = pkgs:
         # pkgs.buildFHSEnv provides only a minimal FHS environment,
         # lacking many basic packages needed by most software.
         # Therefore, we need to add them manually.
         #
         # pkgs.appimageTools provides basic packages required by most software.
         (base.targetPkgs pkgs) ++ (with pkgs; [
           pkg-config
           ncurses
           # Feel free to add more packages here if needed.
         ]
         );
       profile = "export FHS=1";
       runScript = "bash";
       extraOutputsToInstall = ["dev"];
     }))
  ];

  services.blueman.enable = true;
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
    settings = {
      General = {
        Experimental = true;
        FastConnectable = true;
      };
      Policy = {
        AutoEnable = true;
      };
    };
  };

  # Set the default editor to vim
  environment.variables.EDITOR = "xed";
  environment.variables.GTK_IM_MODULE = lib.mkForce "";
  environment.variables.QT_IM_MODULE = lib.mkForce "";

  # Optional: Enable nix-ld for automatic handling of dynamic libraries
  # This is often recommended for seamless integration with non-Nix software.
  programs.nix-ld.enable = true;

  programs.gnupg.agent = {
    enable = true;
    enableSSHSupport = true;
    # pinentryPackage = pkgs.pinentry-qt;
  };

  i18n.inputMethod = {
    type = "fcitx5";
    enable = true;
    fcitx5.addons = with pkgs; [
      fcitx5-gtk   # Or fcitx5-qt for KDE Plasma
      fcitx5-rime
      rime-data
      librime
      qt6Packages.fcitx5-chinese-addons
      fcitx5-nord  # a color theme
    ];
  };

  fonts.packages = with pkgs; [
    nerd-fonts.ubuntu
    nerd-fonts.ubuntu-sans
    nerd-fonts.ubuntu-mono
    nerd-fonts.caskaydia-cove
    noto-fonts
    noto-fonts-cjk-sans
  ];

  system.stateVersion = "25.11";

}
