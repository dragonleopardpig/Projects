# /etc/nixos/configuration.nix

{ inputs, lib, config,  pkgs, ... }:

let
  # SDDM login theme. metadata.desktop's ConfigFile= is rewritten at boot
  # by systemd.services.sddm-random-theme to pick a random variant, so
  # `embeddedTheme` here is only the fallback if the picker doesn't run.
  astronautPkg = pkgs.sddm-astronaut.override {
    embeddedTheme = "pixel_sakura";
    themeConfig = { FormPosition = "left"; };
  };
  # Sioyek chooses a highlight type by pressing h followed by a-z. Mirror its
  # default 26-color palette on those letter keys of either Logitech keyboard.
  # The older GPRO (046d:c339) uses g810-led. The PRO X TKL (046d:c352) uses
  # Solaar's supported HID++ PER_KEY_LIGHTING_V2 live update; its per-key data
  # cannot currently be stored in an onboard profile by a Linux tool.
  sioyekHighlightColors = {
    a = "f0a3ff";
    b = "0075db";
    c = "994000";
    d = "4d005c";
    e = "1a1a1a";
    f = "005c30";
    g = "2bcf47";
    h = "ffcc99";
    i = "808080";
    j = "94ffb5";
    k = "8f7d00";
    l = "9ecc00";
    m = "c20087";
    n = "003380";
    o = "ffa305";
    p = "ffa8ba";
    q = "426600";
    r = "ff000f";
    s = "5ef2f2";
    t = "00998f";
    u = "e0ff66";
    v = "730aff";
    w = "990000";
    x = "ffff80";
    y = "ffff00";
    z = "ff4f05";
  };
  sioyekKeyboardProfile = pkgs.writeText "gpro-sioyek-highlights.profile" (
    "a ffffff\n"
    + lib.concatStringsSep "\n" (
        lib.mapAttrsToList (key: color: "k ${key} ${color}") sioyekHighlightColors
      )
    + "\nc\n"
  );
  gproLedSioyek = pkgs.g810-led.override {
    profile = sioyekKeyboardProfile;
  };
  gproSioyekApply = pkgs.writeShellScriptBin "gpro-sioyek" ''
    exec ${lib.getExe' gproLedSioyek "gpro-led"} -p ${sioyekKeyboardProfile}
  '';
  proXTklSioyekScript = pkgs.writeText "pro-x-tkl-sioyek.py" ''
    #!/usr/bin/env python3
    import sys
    import time

    from logitech_receiver import exceptions
    from logitech_receiver import hidpp20_constants
    from logitech_receiver import settings_templates
    from solaar.cli import _find_device, _receivers_and_devices


    PALETTE = ${builtins.toJSON sioyekHighlightColors}


    def main():
        devices = list(_receivers_and_devices())
        keyboard = next(
            (device for device in _find_device(devices, "pro x tkl") if device.ping()),
            None,
        )
        if keyboard is None:
            print("PRO X TKL is not connected", file=sys.stderr)
            return 2

        lighting = settings_templates.check_feature_setting(
            keyboard, "per-key-lighting"
        )
        led_control = settings_templates.check_feature_setting(keyboard, "rgb_control")
        if lighting is None or led_control is None:
            print("PRO X TKL lighting features are unavailable", file=sys.stderr)
            return 1

        solaar_control = next(
            choice for choice in led_control.choices if str(choice) == "Solaar"
        )
        device_control = next(
            choice for choice in led_control.choices if str(choice) == "Device"
        )
        current_control = led_control.read(cached=False)
        if current_control is None:
            print("Could not read the keyboard LED controller", file=sys.stderr)
            return 1
        # PER_KEY_LIGHTING_V2 leaves its commit engine busy after one complete
        # palette. Cycling control back through the device starts a fresh
        # update session, making repeated Super+F7 presses reliable.
        if current_control == solaar_control:
            if led_control.write(device_control, save=False) is None:
                print("Could not reset the keyboard LED controller", file=sys.stderr)
                return 1
            time.sleep(0.05)
        if led_control.write(solaar_control, save=False) is None:
            print("Could not give Solaar control of the keyboard LEDs", file=sys.stderr)
            return 1

        keys_by_name = {str(key).lower(): int(key) for key in lighting.choices}
        colors = {int(key): 0xFFFFFF for key in lighting.choices}
        for key, color in PALETTE.items():
            colors[keys_by_name[key]] = int(color, 16)

        try:
            lighting.write(colors, save=False)
        except exceptions.FeatureCallError as error:
            # The wireless keyboard can briefly report BUSY when committing a
            # second palette. Its update buffer is already populated, so retry
            # just the commit instead of sending every key again.
            if (
                error.error != hidpp20_constants.ErrorCode.BUSY
                or error.request & 0xF0 != 0x70
            ):
                raise
            for delay in (0.05, 0.1, 0.25, 0.5, 1.0):
                time.sleep(delay)
                try:
                    keyboard.feature_request(lighting.feature, 0x70, 0x00)
                    break
                except exceptions.FeatureCallError as retry_error:
                    if retry_error.error != hidpp20_constants.ErrorCode.BUSY:
                        raise
            else:
                raise
        print("Applied Sioyek palette to PRO X TKL")
        return 0


    if __name__ == "__main__":
        try:
            raise SystemExit(main())
        except Exception as error:
            print(f"Could not update PRO X TKL lighting: {error}", file=sys.stderr)
            raise SystemExit(1)
  '';
  # Add one batch command to Solaar so the entire keyboard is updated in one
  # HID++ transaction instead of starting the Solaar CLI once per key.
  solaarSioyek = pkgs.solaar.overrideAttrs (old: {
    postInstall = (old.postInstall or "") + ''
      install -Dm755 ${proXTklSioyekScript} $out/bin/pro-x-tkl-sioyek
    '';
  });
  sioyekKeyboardApply = pkgs.writeShellScriptBin "sioyek-keyboard-lights" ''
    if ${solaarSioyek}/bin/pro-x-tkl-sioyek; then
      exit 0
    fi

    exec ${lib.getExe gproSioyekApply}
  '';

  # Sioyek renders through MuPDF, which has no DjVu backend, so DjVu files are
  # converted once into a PDF cached beside the source. ddjvu discards the
  # embedded text layer, hence the Tesseract pass: it restores search and also
  # avoids the duplicated hyphen fragments ("at dif- different heights") that
  # older DjVu text layers carry.
  djvuToPdf = pkgs.writeShellApplication {
    name = "djvu2pdf";
    runtimeInputs = with pkgs; [ djvulibre ocrmypdf tesseract coreutils ];
    text = ''
      force=0
      ocr=1
      src=""
      dst=""

      usage() {
        echo "Usage: djvu2pdf [--force] [--no-ocr] <file.djvu> [out.pdf]" >&2
        echo "" >&2
        echo "  --force   reconvert even if the PDF is already up to date" >&2
        echo "  --no-ocr  skip the OCR pass (fast, but leaves no searchable text)" >&2
        echo "" >&2
        echo "Prints the path of the resulting PDF on stdout." >&2
      }

      while [ $# -gt 0 ]; do
        case "$1" in
          --force)   force=1; shift ;;
          --no-ocr)  ocr=0; shift ;;
          -h|--help) usage; exit 0 ;;
          -*)        echo "djvu2pdf: unknown option $1" >&2; usage; exit 2 ;;
          *)         if [ -z "$src" ]; then src="$1"; else dst="$1"; fi; shift ;;
        esac
      done

      if [ -z "$src" ]; then
        usage
        exit 2
      fi
      if [ ! -r "$src" ]; then
        echo "djvu2pdf: cannot read $src" >&2
        exit 1
      fi
      if [ -z "$dst" ]; then
        dst="''${src%.[dD][jJ][vV]*}.pdf"
      fi

      # Up to date already: report the cached PDF and stop.
      if [ "$force" -eq 0 ] && [ -s "$dst" ] && [ "$dst" -nt "$src" ]; then
        echo "$dst"
        exit 0
      fi

      jobs=$(( $(nproc) - 2 ))
      if [ "$jobs" -lt 1 ]; then
        jobs=1
      fi

      tmp=$(mktemp -d)
      trap 'rm -rf "$tmp"' EXIT

      # ddjvu emits benign libtiff IFD warnings on stderr; the exit code is what matters.
      nice -n 15 ddjvu -format=pdf -quality=85 -skip "$src" "$tmp/img.pdf" 2>/dev/null

      if [ "$ocr" -eq 1 ]; then
        # --skip-text keeps the run idempotent if a page ever arrives with text.
        nice -n 15 ocrmypdf --optimize 1 --output-type pdf --skip-text \
          --jobs "$jobs" "$tmp/img.pdf" "$tmp/out.pdf"
      else
        mv "$tmp/img.pdf" "$tmp/out.pdf"
      fi

      mv "$tmp/out.pdf" "$dst"
      echo "$dst"
    '';
  };
in
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

  # Group-writable backlight devices so waybar's backlight/slider (which writes
  # /sys/class/backlight/<dev>/brightness directly) works without root.
  # Covers intel_backlight on M90aPro and ddcciN on X299 hosts.
  services.udev.packages = [ pkgs.brightnessctl gproLedSioyek ];

  # Console font configuration
  console.font = "${pkgs.terminus_font}/share/consolefonts/ter-i20n.psf.gz";
  console.packages = with pkgs; [ terminus_font ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.settings.trusted-users = [ "root" "thinky" ];
  nix.settings.download-buffer-size = 134217728; # 128 MB
  # Leave CPU and memory headroom for the desktop during source builds.
  nix.settings.max-jobs = 2;
  nix.settings.cores = 2;
  nix.gc = {
    automatic = true;
    dates = "daily";
    options = "--delete-older-than 30d";
  };

  # Limit boot entries to prevent /boot from filling up
  boot.loader.grub.configurationLimit = 50;

  hardware.i2c.enable = true;

  # Logitech wireless/wired device support (G502X, PRO Gaming Keyboard)
  hardware.logitech.wireless.enable = true;
  hardware.logitech.wireless.enableGraphical = true;  # Solaar GUI/device access

  # GVFS for Nemo trash, network mounts, etc.
  services.gvfs.enable = true;
  services.udisks2.enable = true;

  # power-profiles-daemon: lets AGS Control Center cycle balanced /
  # performance / power-saver via AstalPowerProfiles (DBus).
  services.power-profiles-daemon.enable = true;


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
        # Picked-up by sddm-random-theme.service: a writable mirror of the
        # astronaut theme dir lives here, with metadata.desktop rewritten
        # to point at a random Themes/<variant>.conf each boot.
        ThemeDir = "/var/lib/sddm/themes";
      };
    };
  };

  # Pick a random sddm-astronaut variant before SDDM starts. Mirrors the
  # upstream theme dir into /var/lib/sddm/themes/sddm-astronaut-theme/ as
  # symlinks, then writes a fresh metadata.desktop pointing at a random
  # *.conf from Themes/.
  systemd.services.sddm-random-theme = {
    description = "Pick a random sddm-astronaut variant for the login screen";
    wantedBy = [ "display-manager.service" ];
    before = [ "display-manager.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ pkgs.coreutils pkgs.gnused pkgs.gnugrep ];
    script = ''
      set -eu
      src=${astronautPkg}/share/sddm/themes/sddm-astronaut-theme
      dst=/var/lib/sddm/themes/sddm-astronaut-theme
      mkdir -p "$dst"
      # Mirror everything from upstream as symlinks, except metadata.desktop
      # which we generate.
      for f in "$src"/* "$src"/.[!.]*; do
        [ -e "$f" ] || continue
        name=$(basename "$f")
        [ "$name" = metadata.desktop ] && continue
        ln -sfn "$f" "$dst/$name"
      done
      # Pick a random *.conf (the *.conf.user override files are excluded
      # by the .conf$ anchor).
      mapfile -t variants < <(ls "$src/Themes/" | grep '\.conf$')
      pick=''${variants[RANDOM % ''${#variants[@]}]}
      sed "s|^ConfigFile=.*|ConfigFile=Themes/$pick|" \
        "$src/metadata.desktop" > "$dst/metadata.desktop"
      echo "sddm-random-theme: picked $pick" >&2
    '';
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
    extraGroups = [ "networkmanager" "wheel" "i2c" "scanner" "lp" "video" ];
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
        "proton-vpn"
        "zoom"
        # Unfree firmware pulled in by hardware.enableAllFirmware on the
        # PortableSSD host (broad device coverage for booting any machine).
        "broadcom-bt-firmware"
        "b43-firmware"
        "xone-dongle-firmware"
        "facetimehd-firmware"
        "facetimehd-calibration"
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
    proton-vpn                 # ProtonVPN graphical client
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
    python3Packages.gpustat    # GPU usage monitor (NVIDIA) — CLI/JSON. (nixpkgs's bare `gpustat` is the unrelated Rust GUI tool.)
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
    gproLedSioyek              # GPRO live/udev profile matching Sioyek highlights
    gproSioyekApply            # Legacy GPRO-only palette command
    sioyekKeyboardApply        # Auto-detect GPRO or PRO X TKL and apply its palette
    power-profiles-daemon      # Power profile management (balanced, performance, saver)
    simple-scan                # Simple GNOME scan GUI (flatbed / quick scans)
    naps2                      # Multi-page ADF → searchable-PDF scanning with OCR
    xsane
    sane-airscan

    # ── Disk & Partitioning ──
    gparted                    # GUI partition editor
    usbimager                  # Write disk images to USB drives
    smartmontools              # SMART health + drive error log (smartctl -d sat /dev/sda
                               # for the USB-attached PortableSSD root)

    # ── Hyprland & Wayland Desktop ──
    awww                       # Animated wallpaper daemon for Wayland
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
    astronautPkg               # SDDM login screen theme (random variant per boot)

    # ── File Managers ──
    nemo-with-extensions       # Cinnamon file manager with plugins
    nemo-fileroller
    cinnamon-desktop           # gsettings schemas for Nemo (terminal, etc.)
    file-roller
    spacedrive                 # Cross-platform file manager

    # ── Image & Media Tools ──
    imagemagick                # Image conversion and manipulation (CLI)
    ffmpeg                     # Audio/video converter and streamer
    ffmpegthumbnailer          # Video thumbnails (used by Emacs Dirvish preview)
    mediainfo                  # Media metadata (used by Emacs Dirvish preview)
    vips                       # Fast image thumbnailing — Dirvish image dispatcher
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
        dirvish                # Yazi-like miller-columns Dired with previews
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
    xvfb-run                   # Run a GUI/render command on a throwaway X display. `Xvfb` itself
                               # already comes in transitively via xorg-server, but only the
                               # wrapper allocates a free display AND tears it down: a leftover
                               # Xvfb wedges user@1000.service at logout, so the NEXT login waits
                               # out the ~90 s stop-timeout. Headless KrakenOS validator/render
                               # runs are the source, e.g. `xvfb-run -a .devenv/state/venv/bin/python
                               # -m KrakenOS.UI.validate_open3d_...`.

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
    gh                         # GitHub CLI

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
    djvuToPdf                  # djvu2pdf: DjVu → searchable PDF for Sioyek
    djvulibre                  # ddjvu/djvused/djvudump for inspecting DjVu directly
    ocrmypdf                   # Adds a searchable text layer to scanned PDFs
    tesseract                  # OCR engine behind ocrmypdf

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
