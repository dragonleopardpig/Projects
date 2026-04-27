# /etc/nixos/configuration.nix

{ inputs, lib, config,  pkgs, ... }:

{
  imports = [];

  boot = {
    kernelPackages = pkgs.linuxPackages_latest;
    kernelModules = ["i2c-dev"];
    initrd.kernelModules = ["nvidia"];
    extraModulePackages = [
      config.boot.kernelPackages.nvidia_x11
    ];
    kernelParams = [
      "quiet"
      "splash"
      "intremap=on"
      "boot.shell_on_fail"
      "udev.log_priority=3"
      "rd.systemd.show_status=auto"
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
    options = "--delete-older-than 30d";
  };

  # Limit boot entries to prevent /boot from filling up
  boot.loader.grub.configurationLimit = 50;

  hardware.i2c.enable = true;

  # Logitech wireless/wired device support (G502X, PRO X TKL)
  hardware.logitech.wireless.enable = true;
  hardware.logitech.wireless.enableGraphical = true;  # Solaar GUI

  # GVFS for Nemo trash, network mounts, etc.
  services.gvfs.enable = true;
  services.udisks2.enable = true;


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
  i18n.supportedLocales = [
    "en_SG.UTF-8/UTF-8"
    "en_US.UTF-8/UTF-8"
    "zh_CN.UTF-8/UTF-8"
  ];
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

  xdg.portal = {
    enable = true;
    xdgOpenUsePortal = false;
    extraPortals = with pkgs; [
      xdg-desktop-portal-gtk
    ];
    config = {
      common = {
        default = [ "hyprland" "gtk" ];
        "org.freedesktop.impl.portal.FileChooser" = [ "gtk" ];
        "org.freedesktop.impl.portal.AppChooser" = [ "gtk" ];
        "org.freedesktop.impl.portal.Print" = [ "gtk" ];
      };
      hyprland = {
        default = [ "hyprland" "gtk" ];
        "org.freedesktop.impl.portal.FileChooser" = [ "gtk" ];
        "org.freedesktop.impl.portal.AppChooser" = [ "gtk" ];
        "org.freedesktop.impl.portal.Print" = [ "gtk" ];
      };
    };
  };

  systemd.user.services.xdg-desktop-portal-gtk = {
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    wantedBy = [ "graphical-session.target" ];
    serviceConfig = {
      Environment = [
        "GDK_BACKEND=wayland"
        "DISPLAY="
        "WAYLAND_DISPLAY=wayland-1"
        "XDG_CURRENT_DESKTOP=Hyprland"
        "XDG_SESSION_TYPE=wayland"
        "XDG_DATA_DIRS=%h/.nix-profile/share:/nix/profile/share:%h/.local/state/nix/profile/share:/etc/profiles/per-user/%u/share:/nix/var/nix/profiles/default/share:/run/current-system/sw/share"
      ];
    };
  };

  systemd.user.services.xdg-desktop-portal = {
    after = [ "xdg-desktop-portal-gtk.service" ];
    wants = [ "xdg-desktop-portal-gtk.service" ];
    serviceConfig = {
      Environment = [
        "XDG_CURRENT_DESKTOP=Hyprland"
        "XDG_SESSION_TYPE=wayland"
        "XDG_DATA_DIRS=%h/.nix-profile/share:/nix/profile/share:%h/.local/state/nix/profile/share:/etc/profiles/per-user/%u/share:/nix/var/nix/profiles/default/share:/run/current-system/sw/share"
      ];
    };
  };

  programs.dconf.enable = true;

  # Enable CUPS to print documents.
  services.printing.enable = true;
  services.printing.drivers = [ pkgs.brlaser ];

  hardware.sane = {
    enable = true;
    brscan4.enable = true;
  };

  services.avahi = {
    enable = true;
    nssmdns4 = true;
  };
  
  # Enable sound with pipewire.
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  # Required for bubblewrap-based FHS env (EasyConnect launcher).
  security.unprivilegedUsernsClone = true;
  boot.kernel.sysctl."user.max_user_namespaces" = 15000;
  security.wrappers.bwrap = {
    source = "${pkgs.bubblewrap}/bin/bwrap";
    owner = "root";
    group = "root";
    setuid = true;
  };
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
    extraGroups = [ "networkmanager" "wheel" "i2c" "scanner" "lp"];
    subGidRanges = [
      {
        count = 65536;
        startGid = 100000;
      }
    ];
    subUidRanges = [
      {
        count = 65536;
        startUid = 100000;
      }
    ];
    packages = with pkgs; [
      #  thunderbird
    ];
    
  };

  # Allow only the specific unfree packages we intentionally use.
  nixpkgs.config.allowUnfreePredicate = pkg:
    let
      name = lib.getName pkg;
      licenses = lib.toList (pkg.meta.license or []);
      hasCudaEula = lib.any (license:
        (license.fullName or "") == "CUDA EULA"
        || (license.shortName or "") == "CUDA EULA"
      ) licenses;
    in
      builtins.elem name [
        "brother-udev-rule-type1"
        "brscan4"
        "claude-code"
        "claude-monitor"
        "codex"
        "corefonts"
        "megasync"
        "nvidia-settings"
        "nvidia-x11"
        "protonvpn-gui"
      ]
      || lib.hasPrefix "brscan4" name
      || hasCudaEula;

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
    dpkg                       # Debian package extractor (for .deb)
    tree                       # Directory listing as tree
    gnused                     # GNU stream editor
    gawk                       # GNU pattern processing language
    gnupg                      # GnuPG encryption and signing
    wget                       # Download files from the web
    yq-go                      # YAML/JSON/XML processor (CLI)
    yt-dlp                    # Download video (NASA APOD video days)

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
    remmina                    # Remote desktop client
    freerdp                    # RDP implementation (needed for Remmina RDP plugins)
    python3
    python3Packages.pygobject3
    gtk3
    spice-protocol             # Needed for some clipboard sync features
    protonvpn-gui              # ProtonVPN graphical client
    onlyoffice-desktopeditors  # ONLYOFFICE desktop editors

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
    zenity                     # GTK dialogs (needed by tinyfiledialogs)
    mesa-demos
    vulkan-tools
    glmark2

    # ── Hardware & Power ──
    brightnessctl              # Screen brightness control
    ddcutil                    # External monitor brightness via DDC/CI
    power-profiles-daemon      # Power profile management (balanced, performance, saver)
    simple-scan
    xsane
    sane-airscan

    # ── Disk & Partitioning ──
    gparted                    # GUI partition editor
    usbimager                  # Write disk images to USB drives

    # ── Hyprland & Wayland Desktop ──
    swww                       # Animated wallpaper daemon for Wayland
    hyprsysteminfo             # Hyprland system info utility
    hyprpolkitagent            # Polkit authentication agent for Hyprland
    waypaper                   # GUI wallpaper setter for Wayland
    slurp                      # Wayland region selector (for screenshots)
    grim                       # Wayland screenshot utility
    wl-clipboard               # Wayland clipboard utilities (wl-copy, wl-paste)
    xclip                      # X11 clipboard utility (for XWayland apps like Remmina)
    copyq                      # Powerful clipboard manager (Wayland + X11 sync)
    libnotify                  # Desktop notification sending (notify-send)
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
    cinnamon-desktop           # gsettings schemas for Nemo (terminal, etc.)
    file-roller
    spacedrive                 # Cross-platform file manager

    # ── Image & Media Tools ──
    imagemagick                # Image conversion and manipulation (CLI)
    ffmpeg                     # Audio/video converter and streamer
    guvcview                   # GUI webcam viewer/recorder
    v4l-utils                  # V4L2 utilities (includes qv4l2)
    gimp                       # GNU image editor (Photoshop alternative)
    inkscape                   # Vector graphics editor (Illustrator alternative)
    pinta                      # Simple raster image editor (Paint.NET alternative)
    imv                        # Wayland-native image viewer
    tiv                        # Terminal image viewer (ASCII art)
    chafa                      # Terminal image viewer (Unicode/sixel)
    viu                        # Terminal image viewer (Unicode)

    # ── Office & Documents ──
    texliveFull                # Full TeX/LaTeX distribution
    hugo                       # Static site generator
    glow                       # Terminal markdown previewer
    minder                     # Mind map

    # ── CAD & Engineering ──
    librecad                   # 2D CAD application
    freecad                    # 3D parametric CAD modeler
    openscad
    mayo
    (python3.withPackages (ps: with ps; [
      pythonocc-core           # OpenCASCADE Python bindings for scripted CAD cleanup
      trimesh                  # Mesh analysis / cleanup helpers
      meshio                   # Mesh format conversion helpers
    ]))
    # ── Emacs & Editor Ecosystem ──
    ((emacsPackagesFor emacs-pgtk).emacsWithPackages (
      epkgs: with epkgs; [
        vterm                  # Terminal emulator inside Emacs
        direnv                 # Direnv integration for Emacs
        lsp-pyright            # Python LSP client (Pyright)
        zmq                    # ZeroMQ bindings for Jupyter
        pyvenv
        codex-cli
        material-theme
	      gruvbox-theme
	      doom-themes
	      ef-themes
	      pdf-tools
	      async
        neotree
        all-the-icons
        rainbow-delimiters
        yaml-mode
        dockerfile-mode
        toml-mode
        json-mode
	      prettier-js
	      js2-refactor
	      rjsx-mode
	      tide
	      web-mode
	      emmet-mode
	      rustic
	      ox-rst
	      alert
	      org-fragtog
	      ob-nix
	      latex-preview-pane
	      org-modern
	      slime
	      nix-mode
	      geiser-mit
	      pyvenv
	      nov
	      markdown-mode
	      mixed-pitch
	      smartparens
	      spice-mode
	      ob-spice
	      saveplace-pdf-view
	      rg
	      ob-rust
	      lua-mode
	      direnv
	      magik-mode
	      treemacs
	      transpose-frame
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
    vale-ls                    # Vale language server (prose/Markdown)

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
    # claude-code                # Anthropic Claude CLI coding assistant
    # claude-monitor             # Claude usage monitoring tool
    # codex
    # gemini-cli

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
           gtk2
           gnome-themes-extra
           gtk-engine-murrine
           gtk3
           glib
           cairo
           pango
           gdk-pixbuf
           atk
           at-spi2-atk
           nss
           nspr
           alsa-lib
           cups
           dbus
           libnotify
           libX11
           libXcomposite
           libXcursor
           libXdamage
           libXext
           libXfixes
           libXi
           libXrandr
           libXrender
           libXtst
           libXScrnSaver
           libxcb
           libxkbcommon
           libdrm
           libgbm
           wget
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

    # ── Cloud ──
    filen-desktop

    # ── Utilities ──
    wget
    
    # ── Fun ──
    cowsay                     # Talking cow ASCII art
  ] ++ (lib.optionals (pkgs ? gmsh) [ pkgs.gmsh ])
    ++ (lib.optionals (pkgs ? f3d) [ pkgs.f3d ])
    ++ (lib.optionals (pkgs ? paraview) [ pkgs.paraview ]);

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

  # Container runtime for distrobox
  virtualisation.podman.enable = true;

  # Provide /usr/bin/wget for apps that hardcode it
  systemd.tmpfiles.rules = [
    "L+ /usr/bin/wget - - - - /run/current-system/sw/bin/wget"
  ];

  # EasyConnect EasyMonitor service (user install path)
  systemd.services.EasyMonitor = {
    description = "Sangfor EasyMonitor Service (EasyConnect)";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    unitConfig = {
      ConditionPathExists = "/usr/share/sangfor/EasyConnect/resources/bin/EasyMonitor";
    };
    serviceConfig = {
      Type = "forking";
      ExecStart = "/usr/share/sangfor/EasyConnect/resources/bin/EasyMonitor";
      ExecReload = "/bin/kill -USR1 $MAINPID";
      ExecStop = "/bin/kill -QUIT $MAINPID";
      Restart = "on-failure";
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
    corefonts
    nerd-fonts.ubuntu
    nerd-fonts.ubuntu-sans
    nerd-fonts.ubuntu-mono
    nerd-fonts.caskaydia-cove
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-cjk-serif
    noto-fonts-color-emoji
    wqy_microhei
    wqy_zenhei
  ];

  system.stateVersion = "25.11";

}
