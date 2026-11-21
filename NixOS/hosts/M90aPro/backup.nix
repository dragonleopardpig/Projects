# Daily backup of the M90aPro pool to the Seagate USB disk (2026-11-21).
#
# The pool keeps one copy of each file across its two SSDs (data "single",
# hosts/M90aPro/pool.nix): a dead SSD loses the files on it, and the backup is
# what brings them back.  User's choice: a daily backup, no mirroring.
#
#   what   /home and /persist (the system itself is rebuilt from this flake),
#          plus extra folders the user adds
#   where  Seagate ST4000DM006, ext4 partition "Linux-Data", repository
#          restic/m90apro on it.  That disk is NOT encrypted, so restic
#          encrypts the backup; its passphrase is the user's, kept off this
#          computer too (without it the backup cannot be read).
#   when   daily at the user's time, catching up after the machine was off or
#          the disk unplugged; skipped while paused or the disk is away.
#
# The bar's Backup icon (noctalia plugin local/backup-status) shows the state
# and edits ~/.config/backup-status/settings.json: daily time, pause, how many
# daily/weekly/monthly snapshots to keep, extra folders and excludes.  The root
# side (scripts/backup-pool.py) reads that file at run time, falling back to
# the defaults below, so none of it needs a rebuild.
#
# Restore: Browse in the icon's dropdown opens a read-only view of every
# snapshot in the file manager (copy files out of it), or `sudo restic-pool
# restore latest --target /tmp/restore --include /home/thinky/<path>`
# (MIGRATE.md, "Backup").  `backup-pool --help` lists every command.
{ pkgs, ... }:
let
  name = "pool";
  user = "thinky";
  diskUuid = "63f1d802-9a75-48b0-9dbe-89a0352456c9"; # Linux-Data on the Seagate
  diskDevice = "/dev/disk/by-uuid/${diskUuid}";
  mountPoint = "/mnt/backup";
  repository = "${mountPoint}/restic/m90apro";
  passwordFile = "/persist/secrets/restic-m90.pass";
  restic = "${pkgs.restic}/bin/restic";
  unit = "restic-backups-${name}.service";
  browseUnit = "restic-browse-${name}.service";
  browseDir = "/run/restic-browse-${name}/mnt";

  # Everything the root helper and the bar plugin need to know, in one place.
  statusConfig = {
    inherit name user unit repository restic;
    browse_unit = browseUnit;
    browse_dir = browseDir;
    mount_point = mountPoint;
    disk_device = diskDevice;
    disk_label = "Seagate Linux-Data";
    settings_file = "/home/${user}/.config/backup-status/settings.json";
    summary_file = "/persist/backup/${name}-status.json";
    excludes_file = "/run/restic-backups-${name}/excludes";
    paths = [ "/home" "/persist" ];
    excludes = [
      "/home/*/.cache"
      "/home/*/.local/share/containers" # podman images: pulled again
      "/home/*/.local/share/Trash"
    ];
    defaults = {
      time = "12:30";
      paused = false;
      keep = { daily = 7; weekly = 4; monthly = 6; };
      extra_paths = [ ];
      extra_excludes = [ ];
    };
  };

  backupPool = pkgs.writeShellApplication {
    name = "backup-pool";
    runtimeInputs = [ pkgs.python3 pkgs.systemd pkgs.libnotify ];
    text = ''exec python3 ${../../scripts/backup-pool.py} "$@"'';
  };
  helper = cmd: "${backupPool}/bin/backup-pool ${cmd}";
  resticEnv = {
    RESTIC_REPOSITORY = repository;
    RESTIC_PASSWORD_FILE = passwordFile;
  };
in
{
  environment.etc."backup-status/${name}.json".text = builtins.toJSON statusConfig;

  # Mounted on first use only: the disk may be unplugged at boot.
  fileSystems.${mountPoint} = {
    device = diskDevice;
    fsType = "ext4";
    options = [
      "noauto" "nofail" "noatime"
      "x-systemd.automount" "x-systemd.idle-timeout=10min" "x-systemd.device-timeout=10s"
    ];
  };

  services.restic.backups.${name} = {
    inherit repository passwordFile;
    initialize = true;
    paths = statusConfig.paths;
    exclude = statusConfig.excludes;
    # The user's extra folders, and their extra excludes (written by prepare).
    dynamicFilesFrom = helper "paths";
    backupPrepareCommand = helper "prepare";
    backupCleanupCommand = helper "summary";
    extraBackupArgs = [
      "--exclude-caches"   # directories tagged CACHEDIR.TAG, e.g. cargo's target/
      "--one-file-system"  # not the rclone cloud mounts inside the home folder
      "--exclude-file=${statusConfig.excludes_file}"
    ];
    # Scheduled by backup-pool-scheduler, which reads the user's time; pruned
    # with the user's keep counts (ExecStartPost below).
    timerConfig = null;
    pruneOpts = [ ];
    # A progress line in the journal every 5 s, for the bar's percentage.
    progressFps = 0.2;
    inhibitsSleep = true;
  };

  systemd.services."restic-backups-${name}" = {
    unitConfig = {
      # Unplugged: skipped, not failed.
      ConditionPathExists = diskDevice;
      RequiresMountsFor = [ "/home" "/persist" mountPoint ];
    };
    serviceConfig = {
      ExecStartPost = [ (helper "forget") ];
      # 3: the snapshot is saved but some files could not be read (they change
      # or vanish while restic reads them).  It counts as done for the day; the
      # icon shows "Done, with warnings" and which files.
      # SIGTERM / 130: stopped (the icon's Stop, a shutdown).  Not a failure: the
      # icon shows "Stopped", and `systemctl --failed` stays clean.
      SuccessExitStatus = [ 3 130 "SIGTERM" "SIGINT" ];
      # Stop waits for restic, then the summary reads the repository.
      TimeoutStopSec = "5min";
    };
  };

  # Every 15 minutes: start the backup when its daily time has passed since the
  # last success (so a missed day runs as soon as the machine and disk are back).
  systemd.services."backup-${name}-scheduler" = {
    description = "Start the ${name} backup when it is due";
    serviceConfig = { Type = "oneshot"; ExecStart = helper "due"; };
  };
  systemd.timers."backup-${name}-scheduler" = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "3min"; OnCalendar = "*:0/15"; AccuracySec = "1min"; };
  };

  # Browse backups: every snapshot, read-only, with the files' own permissions.
  systemd.services."restic-browse-${name}" = {
    description = "Browse the ${name} backup";
    environment = resticEnv // { RESTIC_CACHE_DIR = "/var/cache/restic-browse-${name}"; };
    unitConfig = {
      ConditionPathExists = diskDevice;
      RequiresMountsFor = [ mountPoint ];
    };
    path = [ pkgs.fuse3 ]; # restic mounts through fusermount3
    serviceConfig = {
      # A forgotten browse closes itself (pruning waits while it is open).
      RuntimeMaxSec = "4h";
      RuntimeDirectory = "restic-browse-${name}";
      RuntimeDirectoryMode = "0755";
      CacheDirectory = "restic-browse-${name}";
      CacheDirectoryMode = "0700";
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p ${browseDir}";
      ExecStart = "${restic} mount --allow-other ${browseDir}";
    };
  };

  # The icon's Run now / Stop / Browse: the user may start and stop exactly
  # these two units without a password.
  security.polkit.enable = true;
  security.polkit.extraConfig = ''
    polkit.addRule(function (action, subject) {
      if (action.id == "org.freedesktop.systemd1.manage-units" && subject.user == "${user}") {
        var unit = action.lookup("unit"), verb = action.lookup("verb");
        if ((unit == "${unit}" || unit == "${browseUnit}") &&
            (verb == "start" || verb == "stop" || verb == "restart")) {
          return polkit.Result.YES;
        }
      }
    });
  '';

  # The icon reads the running backup's progress from the system journal.
  users.users.${user}.extraGroups = [ "systemd-journal" ];

  systemd.tmpfiles.rules = [ "d /persist/backup 0755 root root -" ];
  environment.systemPackages = [ backupPool ];
}
