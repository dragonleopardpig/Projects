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
    # Disable USB autosuspend for Logitech G502X
    ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="046d", ATTR{idProduct}=="c099", ATTR{power/autosuspend}="-1"
    # Trigger USB reset service when G502X is detected
    ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="046d", ATTR{idProduct}=="c099", TAG+="systemd", ENV{SYSTEMD_WANTS}="logitech-g502x-reset.service"
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
    options = "--delete-older-than 3d";
  };

  # Limit boot entries to prevent /boot from filling up
  boot.loader.grub.configurationLimit = 5;

  hardware.i2c.enable = true;

  # Logitech wireless/wired device support (G502X, PRO X TKL)
  hardware.logitech.wireless.enable = true;
  hardware.logitech.wireless.enableGraphical = true;  # Solaar GUI

  # GVFS for Nemo trash, network mounts, etc.
  services.gvfs.enable = true;
  services.udisks2.enable = true;

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
          # Try creating ddcci device on every i2c bus; kernel ignores buses without DDC/CI
          echo "ddcci 0x37" > "$bus/new_device" 2>/dev/null || true
        done
      '';
    };
  };

  # USB reset for Logitech G502X (triggered by udev when device appears)
  systemd.services.logitech-g502x-reset = {
    description = "Reset Logitech G502X USB to fix scroll wheel";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "g502x-reset" ''
        sleep 5
        for dev in /sys/bus/usb/devices/*/idProduct; do
          if [ "$(cat "$dev" 2>/dev/null)" = "c099" ]; then
            devpath=$(dirname "$dev")
            echo "Resetting Logitech G502X at $devpath"
            echo 0 > "$devpath/authorized"
            sleep 2
            echo 1 > "$devpath/authorized"
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

    # ── Archive & Compression ──
    zip                        # Create ZIP archives
    unzip                      # Extract ZIP archives
    xz                         # XZ/LZMA compression
    p7zip                      # 7-Zip archive manager
    zstd                       # Zstandard fast compression
    gnutar                     # GNU tar archiver
    peazip                     # Free archive manager utility

    # ── Core Utilities ──
    file                       # Determine file types
    which                      # Locate commands in PATH
    tree                       # Directory listing as tree
    gnused                     # GNU stream editor
    gawk                       # GNU pattern processing language
    gnupg                      # GnuPG encryption and signing
    wget                       # Download files from the web
    yq-go                      # YAML/JSON/XML processor (CLI)

    # ── Networking & Diagnostics ──
    networkmanager             # Network connection manager
    mtr                        # Traceroute + ping network diagnostic
    iperf3                     # Network bandwidth measurement
    dnsutils                   # DNS tools: dig, nslookup
    ldns                       # DNS tool: drill (dig alternative)
    aria2                      # Multi-protocol download utility
    socat                      # Multipurpose network relay (netcat replacement)
    nmap                       # Network discovery and security scanner
    ipcalc                     # IPv4/IPv6 subnet calculator
    traceroute                 # Trace packet route to host
    inetutils                  # Basic networking tools (ftp, telnet, etc.)
    ethtool                    # Ethernet device configuration
    filezilla                  # GUI FTP/SFTP client
    remmina                    # Remote desktop client (RDP, VNC, SSH)
    protonvpn-gui              # ProtonVPN graphical client

    # ── System Monitoring & Debugging ──
    sysstat                    # System performance tools (iostat, mpstat, sar)
    lm_sensors                 # Hardware sensor monitoring (sensors command)
    iotop                      # I/O usage monitor per process
    iftop                      # Network bandwidth monitor per connection
    strace                     # System call tracer
    ltrace                     # Library call tracer
    lsof                       # List open files and sockets
    pciutils                   # PCI device info (lspci)
    usbutils                   # USB device info (lsusb)
    lshw                       # Detailed hardware listing
    gpustat                    # GPU usage monitor (NVIDIA)
    upower                     # Battery and power device info
    mission-center             # GUI system monitor (CPU, RAM, disk, network)
    resources                  # Lightweight GUI resource monitor

    # ── Hardware & Power ──
    brightnessctl              # Screen brightness control
    ddcutil                    # External monitor brightness via DDC/CI
    power-profiles-daemon      # Power profile management (balanced, performance, saver)

    # ── Disk & Partitioning ──
    gparted                    # GUI partition editor
    usbimager                  # Write disk images to USB drives

    # ── Hyprland & Wayland Desktop ──
    swww                       # Animated wallpaper daemon for Wayland
    hyprsysteminfo             # Hyprland system info utility
    hyprpolkitagent            # Polkit authentication agent for Hyprland
    waypaper                   # GUI wallpaper setter for Wayland
    walker                     # Modern app launcher for Wayland
    slurp                      # Wayland region selector (for screenshots)
    grim                       # Wayland screenshot utility
    satty                      # Screenshot annotation tool
    wl-clipboard               # Wayland clipboard utilities (wl-copy, wl-paste)
    libnotify                  # Desktop notification sending (notify-send)
    xdg-desktop-portal         # Desktop integration portal (file picker, etc.)
    xdg-desktop-portal-hyprland # Hyprland-specific portal backend
    xdg-desktop-portal-gtk     # GTK portal backend (file dialogs)

    # ── Themes & Appearance ──
    orchis-theme               # GTK theme (Orchis)
    tela-icon-theme            # Tela icon theme
    tela-circle-icon-theme     # Tela Circle icon theme
    fluent-icon-theme          # Fluent Design icon theme
    adwaita-icon-theme         # GNOME default icon theme
    sassc                      # SASS/SCSS CSS compiler (for theme building)
    (pkgs.sddm-astronaut.override {  # SDDM login screen theme
      embeddedTheme = "pixel_sakura";
      themeConfig = {
        FormPosition = "left";
      };
    })

    # ── File Managers ──
    nemo-with-extensions       # Cinnamon file manager with plugins
    nemo-fileroller
    file-roller
    spacedrive                 # Cross-platform file manager

    # ── Image & Media Tools ──
    imagemagick                # Image conversion and manipulation (CLI)
    ffmpeg                     # Audio/video converter and streamer
    gimp                       # GNU image editor (Photoshop alternative)
    inkscape                   # Vector graphics editor (Illustrator alternative)
    pinta                      # Simple raster image editor (Paint.NET alternative)
    imv                        # Wayland-native image viewer
    tiv                        # Terminal image viewer (ASCII art)
    chafa                      # Terminal image viewer (Unicode/sixel)
    viu                        # Terminal image viewer (Unicode)

    # ── Office & Documents ──
    texliveFull                # Full TeX/LaTeX distribution
    onlyoffice-desktopeditors  # Office suite (Word, Excel, PowerPoint compatible)
    hugo                       # Static site generator
    glow                       # Terminal markdown previewer

    # ── CAD & Engineering ──
    librecad                   # 2D CAD application
    freecad                    # 3D parametric CAD modeler

    # ── Emacs & Editor Ecosystem ──
    ((emacsPackagesFor emacs-pgtk).emacsWithPackages (
      epkgs: with epkgs; [
        vterm                  # Terminal emulator inside Emacs
        direnv                 # Direnv integration for Emacs
        lsp-pyright            # Python LSP client (Pyright)
        zmq                    # ZeroMQ bindings for Jupyter
      ]
    ))
    enchant                  # Spell checking meta-library (used by jinx)
    hunspell                   # Spell checker backend (used by enchant)
    hunspellDicts.en_US        # US English dictionary for hunspell

    # ── Language Servers (LSP) ──
    # System-wide LSPs (used across all projects)
    yaml-language-server       # YAML language server
    vscode-json-languageserver # JSON language server
    bash-language-server       # Bash/shell script language server
    nixd                       # Nix language server
    marksman                   # Markdown language server

    # ── Development Tools ──
    pkg-config                 # Compiler/linker flags helper
    libxml2                    # XML parsing library
    glib                       # GLib core library
    jsonrpc-glib               # JSON-RPC library for GLib
    nodejs_24                  # Node.js JavaScript runtime
    nix-index                  # Nix package file index (nix-locate)
    nix-output-monitor         # Pretty nix build output (nom)
    devenv                     # Developer environment manager
    repomix                    # Repository content mixer for LLM context

    # ── AI Assistants ──
    claude-code                # Anthropic Claude CLI coding assistant
    claude-monitor             # Claude usage monitoring tool

    # ── Containers & Compatibility ──
    distrobox                  # Run other Linux distros in containers
    cryfs                      # Encrypts files locally
    # FHS environment for running non-NixOS binaries
    (let base = pkgs.appimageTools.defaultFhsEnvArgs; in
     pkgs.buildFHSEnv (base // {
       name = "fhs";
       targetPkgs = pkgs:
         (base.targetPkgs pkgs) ++ (with pkgs; [
           pkg-config
           ncurses
         ]);
       profile = "export FHS=1";
       runScript = "bash";
       extraOutputsToInstall = ["dev"];
     }))

    # ── Git & Version Control ──
    git-credential-manager     # Cross-platform Git credential storage

    # ── PDF & Document Viewers ──
    # Sioyek wrapped to use XWayland (native Wayland has issues with NVIDIA)
    (pkgs.symlinkJoin {
      name = "sioyek-wrapped";
      paths = [ pkgs.sioyek ];
      buildInputs = [ pkgs.makeWrapper ];
      postBuild = ''
        wrapProgram $out/bin/sioyek --set QT_QPA_PLATFORM xcb
      '';
    })

    # ── Fun ──
    cowsay                     # Talking cow ASCII art
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
