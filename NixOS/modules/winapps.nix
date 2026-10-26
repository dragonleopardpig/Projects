{ inputs, pkgs, ... }:
let
  configDirectory = "/home/thinky/.config/winapps";
  rdpClient = pkgs.freerdp.overrideAttrs (previous: {
    patches = (previous.patches or [ ]) ++ [ ../patches/freerdp-x11-modifier-state.patch ];
  });
  oemSource = builtins.path { path = "${inputs.winapps}/oem"; name = "winapps-oem"; };
  passwordCommand = pkgs.writeShellScript "winapps-askpass" ''
    exec ${pkgs.gnused}/bin/sed -n s/^PASSWORD=//p ${configDirectory}/credentials.env
  '';
  storageCheck = pkgs.writeShellScript "winapps-storage-check" ''
    set -eu
    if [ "$(${pkgs.util-linux}/bin/findmnt -n -o UUID --mountpoint /mnt/winapps || true)" != fe0516c1-a263-495f-b22d-ef205ead9203 ]; then
      printf 'The Windows VM partition is not mounted at /mnt/winapps.\n' >&2
      exit 1
    fi
    if [ ! -w /mnt/winapps/windows ]; then
      printf 'The Windows VM storage directory is not writable.\n' >&2
      exit 1
    fi
  '';
  runtimePackages = with pkgs; [ podman podman-compose coreutils gnugrep gnused gawk util-linux ];
  winapps = inputs.winapps.packages.${pkgs.stdenv.hostPlatform.system}.winapps.overrideAttrs (previous: {
    postInstall = (previous.postInstall or "") + ''
      wrapProgram "$out/bin/winapps" \
        --run ${storageCheck} \
        --prefix PATH : ${pkgs.lib.makeBinPath runtimePackages}
      wrapProgram "$out/bin/winapps-setup" \
        --run ${storageCheck} \
        --prefix PATH : ${pkgs.lib.makeBinPath runtimePackages}
    '';
  });
  launcher = inputs.winapps.packages.${pkgs.stdenv.hostPlatform.system}.winapps-launcher.override {
    inherit winapps;
  };
  vmCommand = pkgs.writeShellApplication {
    name = "winapps-vm";
    runtimeInputs = [ pkgs.podman pkgs.podman-compose ];
    text = ''
      ${storageCheck}
      exec podman-compose --file ${configDirectory}/compose.yaml "$@"
    '';
  };
  appControl = pkgs.writeShellApplication {
    name = "winapps-apps";
    runtimeInputs = [ pkgs.python3 pkgs.yad pkgs.zenity pkgs.desktop-file-utils winapps ];
    text = ''
      export WINAPPS_COMMAND=${winapps}/bin/winapps
      export WINAPPS_DEFAULT_ICON=${winapps}/src/install/windows.svg
      exec python3 ${../scripts/winapps-apps.py} "$@"
    '';
  };
  resourceControl = pkgs.writeShellApplication {
    name = "winapps-settings";
    runtimeInputs = [ (pkgs.python3.withPackages (pythonPackages: [ pythonPackages.pygobject3 ])) pkgs.podman pkgs.zenity winapps appControl ];
    text = ''
      export GI_TYPELIB_PATH="${pkgs.lib.makeSearchPath "lib/girepository-1.0" (map pkgs.lib.getLib [ pkgs.gtk3 pkgs.pango pkgs.gdk-pixbuf pkgs.at-spi2-core pkgs.harfbuzz pkgs.glib pkgs.gobject-introspection ])}''${GI_TYPELIB_PATH:+:$GI_TYPELIB_PATH}"
      export GDK_PIXBUF_MODULE_FILE=${pkgs.librsvg}/${pkgs.gdk-pixbuf.binaryDir}/loaders.cache
      exec python3 ${../scripts/winapps-memory.py} "$@"
    '';
  };
  memoryControl = pkgs.writeShellScriptBin "winapps-memory" ''
    exec ${resourceControl}/bin/winapps-settings "$@"
  '';
  registerCommand = pkgs.writeShellApplication {
    name = "winapps-register";
    runtimeInputs = with pkgs; [ coreutils gnugrep netcat-openbsd podman winapps ];
    text = ''
      ${storageCheck}
      install -d -m 0700 /home/thinky/.local/state/winapps
      probe_log=/home/thinky/.local/state/winapps/rdp-ready.log
      printf 'Waiting for the Windows Remote Desktop port.\n' > "$probe_log"
      registration_attempt=0
      for retry_attempt in $(seq 1 480); do
        if [ "$(podman inspect --format '{{.State.Running}}' WinApps)" != true ]; then
          printf 'The Windows container stopped before setup finished.\n' >&2
          exit 1
        fi
        guest_address=$(podman inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' WinApps)
        if timeout 5 podman unshare --rootless-netns ${pkgs.netcat-openbsd}/bin/nc -z "$guest_address" 3389; then
          registration_attempt=$((registration_attempt + 1))
          printf 'Checking RemoteApp access and registering applications (attempt %s/5).\n' "$registration_attempt" > "$probe_log"
          if ${winapps}/bin/winapps-setup --user --setupAllOfficiallySupportedApps 2>&1 | tee -a "$probe_log"; then
            exit 0
          else
            setup_result=$?
          fi
          if [ "$setup_result" -ne 14 ] && [ "$setup_result" -ne 15 ]; then
            exit "$setup_result"
          fi
          latest_rdp_log=
          for rdp_log in /home/thinky/.local/share/winapps/FreeRDP_{Test,Scan}_*.log; do
            if [ -f "$rdp_log" ] && { [ -z "$latest_rdp_log" ] || [ "$rdp_log" -nt "$latest_rdp_log" ]; }; then
              latest_rdp_log=$rdp_log
            fi
          done
          if [ -n "$latest_rdp_log" ] && grep -Eq 'STATUS_LOGON_FAILURE|STATUS_ACCOUNT_LOCKED_OUT|Host key verification failed' "$latest_rdp_log"; then
            printf 'Windows rejected the login or certificate. Check %s.\n' "$latest_rdp_log" >&2
            exit "$setup_result"
          fi
          if [ "$registration_attempt" -ge 5 ]; then
            printf 'RemoteApp checks failed five times. Check %s and the Windows console.\n' "$probe_log" >&2
            exit "$setup_result"
          fi
          printf 'Windows app access is not ready. Retrying in 30 seconds.\n' | tee -a "$probe_log"
        fi
        if (( retry_attempt % 20 == 1 )); then
          printf 'Waiting for Windows installation and Remote Desktop to finish starting.\n'
        fi
        sleep 30
      done
      printf 'Timed out waiting for Windows. Check the browser console and container logs.\n' >&2
      exit 1
    '';
  };
in
{
  environment.systemPackages = [ winapps launcher vmCommand resourceControl memoryControl appControl pkgs.podman-compose ];
  users.users.thinky.extraGroups = [ "kvm" ];

  home-manager.users.thinky = { config, lib, ... }: {
    xdg.configFile."winapps/.env".source = config.lib.file.mkOutOfStoreSymlink "${configDirectory}/memory.env";

    xdg.desktopEntries.winapps-settings = {
      name = "WinApps";
      comment = "Open Windows and manage apps, CPU/RAM, fullscreen, scaling, and shutdown";
      exec = "${resourceControl}/bin/winapps-settings";
      icon = "preferences-system";
      terminal = false;
      categories = [ "Settings" "System" ];
      settings.Keywords = "WinApps;Windows;RAM;Memory;CPU;Cores;Office;Teams;Apps;Fullscreen;Shutdown;";
    };

    wayland.windowManager.hyprland.extraConfig = ''
      windowrule {
        name = winapps-settings-dialogs
        match:class = ^(yad|io.github.winapps.Settings)$
        match:title = ^(WinApps|Choose Windows Apps)$
        float = yes
        center = yes
      }

      windowrule {
        name = winapps-office-windows
        match:class = ^Microsoft (Word|Excel|PowerPoint|Outlook|OneNote|Access|Teams)$
        float = yes
        no_anim = yes
        no_follow_mouse = yes
        suppress_event = maximize fullscreen
      }

      windowrule {
        name = winapps-office-marker
        match:class = ^Microsoft (Word|Excel|PowerPoint|Outlook|OneNote|Access|Teams)$
        match:title = ^RemoteApp Marker Window$
        no_focus = yes
        border_size = 0
        no_shadow = yes
        no_blur = yes
      }
    '';

    xdg.configFile."winapps/compose.yaml".text = ''
      name: winapps
      services:
        windows:
          image: ghcr.io/dockur/windows@sha256:59f8bed19cfd49cf1701debe34f9df6311e61a4e2ae68aa9f41206e2184e31cc
          container_name: WinApps
          env_file:
            - ${configDirectory}/credentials.env
          environment:
            VERSION: "11"
            LANGUAGE: "English"
            REGION: "en-SG"
            KEYBOARD: "en-US"
            USERNAME: "thinky"
            RAM_SIZE: "''${WINAPPS_RAM_SIZE:-4G}"
            CPU_CORES: "''${WINAPPS_CPU_CORES:-4}"
            DISK_SIZE: "64G"
            ALLOCATE: "N"
            CONNECTIONS: "16"
            NETWORK: "user"
            CPU_FLAGS: "arch_capabilities=off"
          ports:
            - "127.0.0.1:8006:8006"
            - "127.0.0.1:3389:3389/tcp"
            - "127.0.0.1:3389:3389/udp"
          cap_add:
            - NET_ADMIN
            - NET_RAW
          devices:
            - /dev/kvm
            - /dev/net/tun
          group_add:
            - keep-groups
          volumes:
            - /mnt/winapps/windows:/storage
            - ${oemSource}:/oem:ro
          stop_grace_period: 120s
          restart: "no"
    '';

    xdg.configFile."winapps/winapps.conf".text = ''
      RDP_USER="thinky"
      RDP_ASKPASS="${passwordCommand}"
      RDP_DOMAIN=""
      RDP_IP="127.0.0.1"
      RDP_PORT="3389"
      WAFLAVOR="podman"
      RDP_SCALE="100"
      RDP_DESKTOP_SCALE="$(${pkgs.gnused}/bin/sed -n 's/^WINAPPS_DESKTOP_SCALE=//p' ${configDirectory}/memory.env)"
      RDP_FULLSCREEN="$(${pkgs.gnused}/bin/sed -n 's/^WINAPPS_FULLSCREEN=//p' ${configDirectory}/memory.env)"
      REMOVABLE_MEDIA="/run/media"
      RDP_FLAGS="/cert:tofu /sound /microphone +home-drive /kbd:unicode:off /clipboard:direction-to:all /sec:nla /timeout:30000 /size:100% -grab-mouse +fonts"
      FREERDP_COMMAND="${rdpClient}/bin/xfreerdp"
      AUTOPAUSE="on"
      AUTOPAUSE_TIME="300"
      DEBUG="false"
      BOOT_TIMEOUT="300"
      PORT_TIMEOUT="15"
      RDP_TIMEOUT="60"
      APP_SCAN_TIMEOUT="120"
      HIDEF="off"
    '';

    home.activation.winappsCredentials = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      install -d -m 0700 ${configDirectory}
      if [ ! -s ${configDirectory}/credentials.env ]; then
        (
          umask 077
          windows_password="$(${pkgs.openssl}/bin/openssl rand -hex 24)"
          printf 'PASSWORD=%s\n' "$windows_password" > ${configDirectory}/credentials.env
        )
      fi
      chmod 0600 ${configDirectory}/credentials.env
      if [ ! -e ${configDirectory}/memory.env ]; then
        (
          umask 077
          printf 'WINAPPS_RAM_SIZE=4G\nWINAPPS_CPU_CORES=4\n' > ${configDirectory}/memory.env
        )
      fi
      chmod 0600 ${configDirectory}/memory.env
    '';

    home.activation.winappsLaunchers = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      for desktop_file in /home/thinky/.local/share/applications/*.desktop; do
        if [ -f "$desktop_file" ] && [ ! -L "$desktop_file" ] && \
            ${pkgs.gnugrep}/bin/grep -qE '^Exec=/nix/store/[^/]+-winapps[^/]*/bin/winapps ' "$desktop_file"; then
          ${pkgs.gnused}/bin/sed -i -E \
            's|^Exec=/nix/store/[^/]+-winapps[^/]*/bin/winapps |Exec=${winapps}/bin/winapps |' "$desktop_file"
          launcher_name=''${desktop_file##*/}
          launcher_file="/home/thinky/.local/bin/''${launcher_name%.desktop}"
          if [ -f "$launcher_file" ] && [ ! -L "$launcher_file" ]; then
            ${pkgs.gnused}/bin/sed -i -E \
              's|^(exec )?/nix/store/[^/]+-winapps[^/]*/bin/winapps |exec ${winapps}/bin/winapps |' "$launcher_file"
          fi
        fi
      done
    '';


    systemd.user.services.winapps-vm = {
      Unit.Description = "Windows VM for WinApps";
      Service = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${vmCommand}/bin/winapps-vm up -d";
        ExecStop = "${vmCommand}/bin/winapps-vm stop";
        TimeoutStartSec = 300;
        TimeoutStopSec = 180;
      };
    };

    systemd.user.services.winapps-register = {
      Unit = {
        Description = "Register applications after Windows installation";
        Requires = [ "winapps-vm.service" ];
        After = [ "winapps-vm.service" ];
      };
      Service = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${registerCommand}/bin/winapps-register";
        TimeoutStartSec = "6h";
      };
    };

  };
}
