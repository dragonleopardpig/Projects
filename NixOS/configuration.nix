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
  sioyekKeyboardApply = pkgs.callPackage ./packages/sioyek-keyboard-lights.nix {};

  # djvu2pdf: DjVu -> searchable PDF. Its own repo now; ddjvu drops the hidden
  # text layer, so the OCR pass is what makes the output searchable at all.
  # Still useful alongside native DjVu: this gives a clean text layer, where the
  # DjVu's own carries the hyphen-duplication fault.
  djvuToPdf = inputs.djvu2pdf.packages.${pkgs.stdenv.hostPlatform.system}.default;

  # pdf-prep: whiten, speed up and OCR a scanned PDF, doing only what each scan
  # needs. Its ~575 lines used to be embedded here; it is now its own repo, so
  # edit https://github.com/dragonleopardpig/pdf-prep and bump the flake input.
  pdfPrep = inputs.pdf-prep.packages.${pkgs.stdenv.hostPlatform.system}.default;

  wlCopyImage = pkgs.callPackage ./packages/wl-copy-image.nix {};
  sioyekSnip = pkgs.callPackage ./packages/sioyek-snip.nix { inherit wlCopyImage; };

  rimeGoogleCloudClient = pkgs.callPackage ./packages/librime-cloud-client.nix {};

  # Rime configuration overlay: selects rime-ice Full Pinyin as the active
  # schema and inserts the Google Cloud Pinyin Lua filter after long_word_filter.
  rimeCustomData = pkgs.runCommand "rime-custom-data" { } ''
    mkdir -p $out/share/rime-data/lua

    cat << 'EOF' > $out/share/rime-data/default.custom.yaml
    patch:
      __include: rime_ice_suggestion:/
      schema_list:
        - schema: rime_ice
      menu/page_size: 7
    EOF

    cat << 'EOF' > $out/share/rime-data/rime_ice.custom.yaml
    patch:
      "engine/filters":
        - lua_filter@*corrector
        - reverse_lookup_filter@radical_reverse_lookup
        - lua_filter@*autocap_filter
        - lua_filter@*v_filter
        - lua_filter@*pin_cand_filter
        - lua_filter@*long_word_filter
        - lua_filter@*google_cloud_pinyin
        - lua_filter@*reduce_english_filter
        - simplifier@emoji
        - simplifier@traditionalize
        - lua_filter@*search@radical_pinyin
        - uniquifier
    EOF

    cat << 'EOF' > $out/share/rime-data/lua/google_cloud_pinyin.lua
    local M = {}
    local client = nil
    local cache = {}
    local cache_order = {}
    local MAX_CACHE = 512

    function M.init(env)
        if not client then
            local ok, loader = pcall(package.loadlib, "${rimeGoogleCloudClient}/lib/librime_cloud_client.so", "luaopen_rime_cloud")
            if ok and type(loader) == "function" then
                local ok2, mod = pcall(loader)
                if ok2 and type(mod) == "table" then
                    client = mod
                end
            end
        end
    end

    local function query_cloud(clean_code)
        if cache[clean_code] ~= nil then
            return cache[clean_code]
        end
        if not client or not client.query then
            return ""
        end
        local ok, res = pcall(client.query, clean_code)
        local text = (ok and type(res) == "string") and res or ""
        if text ~= "" then
            cache[clean_code] = text
            table.insert(cache_order, clean_code)
            if #cache_order > MAX_CACHE then
                local oldest = table.remove(cache_order, 1)
                cache[oldest] = nil
            end
        end
        return text
    end

    function M.func(input, env)
        local code = env.engine.context.input or ""
        if not code:match("^[a-z']+$") or code:match("^v") then
            for cand in input:iter() do
                yield(cand)
            end
            return
        end
        local clean_code = code:gsub("'", "")
        if #clean_code < 4 or #clean_code > 40 then
            for cand in input:iter() do
                yield(cand)
            end
            return
        end

        local cloud_text = query_cloud(clean_code)
        if cloud_text == "" then
            for cand in input:iter() do
                yield(cand)
            end
            return
        end

        local first = true
        local inserted_cloud = false
        for cand in input:iter() do
            if first then
                first = false
                if cand.text == cloud_text then
                    local cmt = cand.comment or ""
                    if not cmt:find("☁", 1, true) then
                        cmt = (cmt == "") and "☁" or (cmt .. " ☁")
                    end
                    yield(Candidate(cand.type, cand.start, cand._end, cand.text, cmt))
                    inserted_cloud = true
                else
                    yield(cand)
                    local cloud_cand = Candidate("cloud", 0, #code, cloud_text, "☁")
                    yield(cloud_cand)
                    inserted_cloud = true
                end
            else
                if not (inserted_cloud and cand.text == cloud_text and cand._end == #code) then
                    yield(cand)
                end
            end
        end
    end

    return M
    EOF
  '';

  # Fcitx5 classic UI theme matching Noctalia Suite OLO-Neon palette
  fcitx5OloNeonTheme = pkgs.runCommand "fcitx5-olo-neon-theme" { } ''
    dir="$out/share/fcitx5/themes/OLO-Neon"
    mkdir -p "$dir"
    cp "${pkgs.fcitx5-nord}/share/fcitx5/themes/Nord-Dark/arrow.png" "$dir/"
    cp "${pkgs.fcitx5-nord}/share/fcitx5/themes/Nord-Dark/radio.png" "$dir/"

    cat << 'EOF' > "$dir/theme.conf"
    [Metadata]
    Name=OLO-Neon
    Version=1.0
    Author=NixOS
    Description=OLO-Neon theme matching Noctalia Suite
    ScaleWithDPI=True

    [InputPanel]
    Font=Inter 13
    NormalColor=#E9FFF8
    HighlightCandidateColor=#00F5C8
    HighlightColor=#00F5C8
    HighlightBackgroundColor=#164A43
    Spacing=4

    [InputPanel/TextMargin]
    Left=10
    Right=10
    Top=6
    Bottom=6

    [InputPanel/Background]
    Color=#080D19
    BorderColor=#FF149E
    BorderWidth=2

    [InputPanel/Background/Margin]
    Left=4
    Right=4
    Top=4
    Bottom=4

    [InputPanel/Highlight]
    Color=#164A43

    [InputPanel/Highlight/Margin]
    Left=10
    Right=10
    Top=6
    Bottom=6

    [Menu]
    Font=Inter 11
    NormalColor=#E9FFF8
    HighlightCandidateColor=#00F5C8
    Spacing=3

    [Menu/Background]
    Color=#080D19
    BorderColor=#FF149E
    BorderWidth=2

    [Menu/Background/Margin]
    Left=4
    Right=4
    Top=4
    Bottom=4

    [Menu/ContentMargin]
    Left=2
    Right=2
    Top=2
    Bottom=2

    [Menu/Highlight]
    Color=#164A43

    [Menu/Highlight/Margin]
    Left=10
    Right=10
    Top=5
    Bottom=5

    [Menu/Separator]
    Color=#2A4757

    [Menu/CheckBox]
    Image=radio.png

    [Menu/SubMenu]
    Image=arrow.png

    [Menu/TextMargin]
    Left=5
    Right=5
    Top=5
    Bottom=5
    EOF
  '';
in
{
  imports = [
    ./modules/always-on.nix
    ./modules/hyprfm.nix
  ];

  boot = {
    kernelPackages = pkgs.linuxPackages_latest;
    kernelModules = ["i2c-dev"];
    # NOTE: no NVIDIA here.  This file is shared by every host, so pinning
    # nvidia_x11 (and an initrd "nvidia") forced one machine's GPU onto all of
    # them, and hosts/universal-boot.nix then had to mkForce it back off --
    # which also wiped the *real* driver that hardware.nvidia contributes.
    # Each host declares its own GPU (hosts/*/nvidia*.nix); the NixOS nvidia
    # module adds the right module package and kernel params by itself.
    kernelParams = [
      "intremap=on"
      "boot.shell_on_fail"
      "udev.log_priority=3"
    ];
    # silence first boot output
    consoleLogLevel = 3;
    # The initrd is always systemd's now (nixpkgs dropped the scripted one in 2026-11); the
    # impermanence rollback and the pool's unlock run as initrd systemd units.

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
  services.udev.packages = [ pkgs.brightnessctl sioyekKeyboardApply.gproLed ];

  # Console font configuration
  console.font = "${pkgs.terminus_font}/share/consolefonts/ter-i20n.psf.gz";
  console.packages = with pkgs; [ terminus_font ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.settings.trusted-users = [ "root" "thinky" ];
  nix.settings.download-buffer-size = 134217728; # 128 MB
  # Leave CPU and memory headroom for the desktop during source builds.
  nix.settings.max-jobs = 2;
  nix.settings.cores = 2;
  nix.settings.auto-optimise-store = true;
  nix.gc = {
    automatic = true;
    dates = "daily";
    options = "--delete-older-than 7d";
  };

  # Limit boot entries to prevent /boot from filling up
  boot.loader.grub.configurationLimit = 50;

  hardware.i2c.enable = true;

  # Logitech wireless/wired device support (G502X, PRO Gaming Keyboard)
  hardware.logitech.wireless.enable = true;
  programs.solaar.enable = true;  # Solaar GUI/device access (was hardware.logitech.wireless.enableGraphical)

  # GVFS for file-manager trash and network mounts.
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
  networking.enableIPv6 = false;

  # Recover Intel CNVi/PCI Wi-Fi (0000:80:14.3 [8086:7f70]) if iwl_pci_probe
  # fails its early MAC handshake across a warm reboot or BIOS setup exit.
  systemd.services.iwlwifi-pci-recover = {
    description = "Recover unbound Intel CNVi/PCI Wi-Fi controller via PCI FLR";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-udev-trigger.service" "systemd-modules-load.service" ];
    before = [ "NetworkManager.service" "network-pre.target" ];
    wants = [ "network-pre.target" ];
    restartIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "iwlwifi-pci-recover" ''
        for dev in /sys/bus/pci/devices/*; do
          [ -e "$dev/class" ] && [ -e "$dev/vendor" ] || continue
          if [ "$(cat "$dev/class" 2>/dev/null)" = "0x028000" ] && \
             [ "$(cat "$dev/vendor" 2>/dev/null)" = "0x8086" ]; then
            [ -e "$dev/driver" ] && continue
            bdf=$(basename "$dev")
            for _ in 1 2 3 4 5 6; do
              [ -e "$dev/driver" ] && break
              sleep 0.5
            done
            [ -e "$dev/driver" ] && continue
            echo "iwlwifi-pci-recover: $bdf has no driver bound; resetting PCI function and re-probing iwlwifi"
            ${pkgs.kmod}/bin/modprobe iwlwifi || true
            if [ -w "$dev/reset" ]; then
              echo 1 > "$dev/reset" || true
              sleep 1
            fi
            echo "$bdf" > /sys/bus/pci/drivers_probe 2>/dev/null || \
              echo "$bdf" > /sys/bus/pci/drivers/iwlwifi/bind 2>/dev/null || true
            if [ ! -e "$dev/driver" ] && [ -w "$dev/remove" ] && [ -w /sys/bus/pci/rescan ]; then
              echo "iwlwifi-pci-recover: $bdf still unbound after FLR; rescanning PCI bus"
              echo 1 > "$dev/remove" || true
              sleep 1
              echo 1 > /sys/bus/pci/rescan || true
            fi
          fi
        done
      '';
    };
  };

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

  programs.appimage.enable = true;

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

  # Fast session shutdown: prevent misbehaving user processes from stalling logout
  systemd.user.settings.Manager.DefaultTimeoutStopSec = "4s";

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

  # nixpkgs' avahi-daemon unit is sandboxed (ProtectSystem=strict, bounding
  # set = SYS_CHROOT/SETUID/SETGID only). Once a stale /run/avahi-daemon/pid
  # exists, every start fails with "Failed to create PID file: File exists":
  # libdaemon's stale-PID unlink runs as root BEFORE avahi drops to its own
  # user, root has no CAP_DAC_OVERRIDE in the avahi-owned directory, and the
  # failed unlink is ignored. That turned `nixos-rebuild switch` into exit 4 on
  # 2026-09-13 (X299-SSD).
  #
  # The stale file came from a boot-time race: openresolv's
  # libc.d/avahi-daemon hook (run by resolvconf.service) SIGHUPs the PID in
  # that file, and when the signal lands in the ~1 ms between avahi writing the
  # file and installing its signal handler, the daemon dies. systemd counts a
  # SIGHUP death as a clean exit, so nothing is logged and Restart=on-failure
  # would not fire; cups-browsed (BindsTo=avahi-daemon) then stays dead too.
  systemd.services.avahi-daemon = {
    # Let the boot-time resolvconf run finish before avahi exists, so its hook
    # finds no PID file to signal. Harmless on hosts without resolvconf.service.
    after = [ "resolvconf.service" ];
    serviceConfig = {
      # '+' runs this outside the sandbox with full privileges.
      ExecStartPre = "+${pkgs.coreutils}/bin/rm -f /run/avahi-daemon/pid";
      # Recover from any signal death during startup (clean exit to systemd).
      Restart = "always";
      RestartSec = 1;
    };
  };
  
  # Enable sound with pipewire.
  services.pulseaudio.enable = false;
  # Full Magic SysRq.  The default here was 16 (sync only), which left no way
  # out when a session lock's client died: the lock cannot be dismissed, there
  # was no getty to reach and no sshd, so the only option was the power button.
  # With this, Alt+SysRq+R takes the keyboard out of raw mode -- which is what
  # a compositor holding an input grab breaks -- and REISUB shuts down cleanly
  # instead of cutting power under a mounted filesystem.  It needs physical
  # keyboard access, which on a laptop is no weaker than the power button.
  boot.kernel.sysctl."kernel.sysrq" = 1;

  # Closing the lid must not suspend this machine while it is on mains power.
  #
  # 2026-09-23: the lid was shut at the SDDM greeter, the password went in, and
  # both screens went black for good.  That boot's journal:
  #
  #   08:28:41  systemd-logind: Lid closed.
  #   08:28:47  sddm: Authentication for user "thinky" successful
  #   08:28:48  sddm-helper: Jumping to VT 2        <- the greeter lets the GPU go
  #   08:28:49  systemd-logind: Suspending...
  #   08:28:50  kernel: PM: suspend entry (s2idle) / Filesystems sync
  #   (no further kernel line, no resume; 08:29:22 "Lid opened" did nothing)
  #
  # logind counts an external display only where a DRM connector's sysfs
  # `enabled` attribute reads "enabled", and the NVIDIA driver never sets it
  # here -- with the desktop live on HDMI-A-1 every connector still reads
  # `enabled=disabled`.  HandleLidSwitchDocked can therefore never apply on
  # this laptop, so a lid-close event always lands on HandleLidSwitch=suspend.
  # It was merely deferred while the greeter's weston held the outputs, and
  # fired the instant SDDM handed the GPU to the session being logged into.
  #
  # The suspend then never completed: the kernel printed nothing after the
  # filesystem sync -- NVIDIA's PM_SUSPEND_PREPARE notifier runs before user
  # space is frozen, and the new session was initialising the GPU at that
  # exact moment -- while systemd-sleep had already cgroup-frozen user.slice.
  # System services carried on (nix-gc finished at 08:29:16), but every user
  # session stayed frozen with no compositor on either screen, which is why
  # the lid, the keyboard and the mouse were all dead.  Nothing here can
  # promise that NVIDIA's suspend path returns, so the fix is to stop firing
  # it by accident.
  #
  # On mains power the lid switch is now ignored outright; the panel still
  # goes dark, because Hyprland disables eDP-1 on lid close by itself.  On
  # battery HandleLidSwitch=suspend still applies, which is what a laptop
  # being shut and carried off should do.  Desktops have no lid switch, so
  # this is inert on them.  Takes effect at the next boot: logind is
  # restartIfChanged = false, and restarting it under Wayland would yank the
  # DRM and input handles out from under the running session.
  services.logind.settings.Login.HandleLidSwitchExternalPower = "ignore";

  # Give hyprlock its own PAM stack.  Without one it falls back to `su`, whose
  # auth chain carries pam_rootok, pam_faillock and pam_xauth -- none of which
  # belong in a screen locker -- and the failures show up in the log as
  # `pam_unix(su:auth)`.  An empty definition here generates the same clean
  # unix stack that swaylock and xlock already get.
  security.pam.services.hyprlock = { };

  security.rtkit.enable = true;
  # Bubblewrap-based FHS env (EasyConnect launcher): user namespaces.  (The kernel allows
  # unprivileged ones by default; `security.unprivilegedUsernsClone` was removed 2026-11.)
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

  # GTK 2 is flagged "broken" in nixpkgs since 2026-11 (to be removed before NixOS 27.05);
  # xsane (and sane-frontends) still use it.  Warn instead of refusing until xsane moves on;
  # simple-scan and naps2 below are GTK 3.
  nixpkgs.config.problems.handlers."gtk+".broken = "warn";

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
        "antigravity"
        "antigravity-ide"         # its package name since nixpkgs 2026-11
        "brother-udev-rule-type1"
        "brscan4"
        "claude-code"
        "claude-monitor"
        "codex"
        "corefonts"
        "megasync"
        "nvidia-kernel-modules"   # split out of nvidia-x11 in nixpkgs 2026-11
        "nvidia-settings"
        "nvidia-x11"
        "proton-vpn"
        "scramble-desktop"
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
    rclone-browser
    (callPackage ./packages/rclone-control { })
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
    sioyekKeyboardApply.gproLed          # GPRO live/udev profile matching Sioyek highlights
    sioyekKeyboardApply.gproSioyekApply  # Legacy GPRO-only palette command
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

    # ── Archive Tools (HyprFM is provided by modules/hyprfm.nix) ──
    file-roller

    # ── Image & Media Tools ──
    imagemagick                # Image conversion and manipulation (CLI)
    potrace                    # Local raster-to-SVG tracing for Minder
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
    libreoffice                # Office suite
    texliveFull                # Full TeX/LaTeX distribution
    hugo                       # Static site generator
    glow                       # Terminal markdown previewer
    minder                     # Mind map
    formulaocr-offline         # Local PP-FormulaNet image-to-LaTeX recognition for Minder

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
	      # (its home, depp.brause.cc, serves an expired TLS certificate since
	      # 2026-11: the same commit from the emacsmirror copy, same hash)
	      (nov.overrideAttrs (old: {
	        src = old.src.override { url = "https://github.com/emacsmirror/nov.git"; };
	      }))
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
    lapce                      # Lightning-fast Rust-based code editor
    xvfb-run                   # Run a GUI/render command on a throwaway X display. `Xvfb` itself
                               # already comes in transitively via xorg-server, but only the
                               # wrapper allocates a free display AND tears it down: a leftover
                               # Xvfb wedges user@1000.service at logout, so the NEXT login waits
                               # out the ~90 s stop-timeout. Headless KrakenOS validator/render
                               # runs are the source, e.g. `xvfb-run -a .devenv/state/venv/bin/python
                               # -m KrakenOS.UI.validate_open3d_...`.

    # ── AI Assistants ──
    antigravity-ide            # Google Antigravity IDE (official agentic desktop IDE)
    claude-code                # Anthropic Claude CLI coding assistant
    claude-monitor             # Claude usage monitoring tool
    codex                      # OpenAI Codex CLI
    # gemini-cli

    # ── Containers & Compatibility ──
    distrobox                  # Run other Linux distros in containers
    gocryptfs                  # Encrypts files locally (cryfs left nixpkgs in 2026-11 with FUSE 2)
    # FHS environment for running non-NixOS binaries
    (let base = pkgs.appimageTools.defaultFhsEnvArgs; in
     pkgs.buildFHSEnv (base // {
       name = "fhs";
       targetPkgs = pkgs:
         (base.targetPkgs pkgs) ++ (with pkgs; [
           pkg-config
           ncurses
           zstd
           gtk2
           gnome-themes-extra
           # (gtk-engine-murrine, a GTK 2 theme engine, left nixpkgs in 2026-11)
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
    pkgs.sioyek
    djvuToPdf                  # djvu2pdf: DjVu → searchable PDF for Sioyek
    pdfPrep                    # pdf-prep: whiten, speed up and OCR a scanned PDF
    sioyekSnip                 # sioyek-snip: crop a dragged rectangle out of a page
    wlCopyImage                # wl-copy-image: Wayland multi-format image clipboard (PNG, BMP for WinApps/Wine)
    djvulibre                  # ddjvu/djvused/djvudump for inspecting DjVu directly
    ocrmypdf                   # Adds a searchable text layer to scanned PDFs
    tesseract                  # OCR engine behind ocrmypdf

    # ── Cloud ──
    filen-desktop

    # ── Utilities ──
    wget
    
    # ── Fun ──
    cowsay                     # Talking cow ASCII art
  ] ++ (lib.optionals (pkgs ? gmsh) [ pkgs.gmsh ]);

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

  # Set the default editor
  environment.variables.EDITOR = "lapce";
  environment.variables.VISUAL = "lapce";
  environment.variables.MINDER_FORMULA_OCR = "/run/current-system/sw/bin/formulaocr-offline";
  environment.variables.MINDER_POTRACE = lib.getExe' pkgs.potrace "potrace";

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
    fcitx5.waylandFrontend = true;
    fcitx5.addons = with pkgs; [
      fcitx5-gtk
      (fcitx5-rime.override {
        rimeDataPkgs = [
          pkgs.rime-ice
          pkgs.rime-data
          rimeCustomData
        ];
      })
      librime
      qt6Packages.fcitx5-chinese-addons
      fcitx5OloNeonTheme
      fcitx5-nord
    ];
  };

  fonts.packages = with pkgs; [
    corefonts
    (callPackage ./packages/caveat.nix { })
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
    # Latin Modern Math is the OpenType successor to Computer Modern, so LaTeX in
    # Sioyek's note boxes (and \mathcal in particular) matches what TeX produces.
    lmodern
  ];

  system.stateVersion = "25.11";

}
