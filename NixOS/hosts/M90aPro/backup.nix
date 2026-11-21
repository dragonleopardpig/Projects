# Daily backup of the M90aPro pool to the Seagate USB disk (2026-11-21).
#
# The pool keeps one copy of each file across its two SSDs (data "single",
# hosts/M90aPro/pool.nix): a dead SSD loses the files on it, and the backup is
# what brings them back.  User's choice: a daily backup, no mirroring.
#
#   what   /home and /persist (the system itself is rebuilt from this flake)
#   where  Seagate ST4000DM006, ext4 partition "Linux-Data", repository
#          restic/m90apro on it.  That disk is NOT encrypted, so restic
#          encrypts the backup; its passphrase is the user's, kept off this
#          computer too (without it the backup cannot be read).
#   when   daily, catching up after the machine was off; skipped quietly while
#          the disk is unplugged.
#
# Restore: `sudo restic-pool snapshots`, `sudo restic-pool restore latest
# --target /tmp/restore --include /home/thinky/<path>` (MIGRATE.md, "Backup").
{ ... }:
let
  diskUuid = "63f1d802-9a75-48b0-9dbe-89a0352456c9"; # Linux-Data on the Seagate
  mountPoint = "/mnt/backup";
in
{
  # Mounted on first use only: the disk may be unplugged at boot.
  fileSystems.${mountPoint} = {
    device = "/dev/disk/by-uuid/${diskUuid}";
    fsType = "ext4";
    options = [
      "noauto" "nofail" "noatime"
      "x-systemd.automount" "x-systemd.idle-timeout=10min" "x-systemd.device-timeout=10s"
    ];
  };

  services.restic.backups.pool = {
    repository = "${mountPoint}/restic/m90apro";
    initialize = true;
    passwordFile = "/persist/secrets/restic-m90.pass";
    paths = [ "/home" "/persist" ];
    exclude = [
      "/home/*/.cache"
      "/home/*/.local/share/containers" # podman images: pulled again
      "/home/*/.local/share/Trash"
    ];
    extraBackupArgs = [
      "--exclude-caches"   # directories tagged CACHEDIR.TAG, e.g. cargo's target/
      "--one-file-system"  # not the rclone cloud mounts inside the home folder
    ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
    pruneOpts = [ "--keep-daily 7" "--keep-weekly 4" "--keep-monthly 6" ];
    inhibitsSleep = true;
  };

  systemd.services.restic-backups-pool.unitConfig = {
    # Unplugged: skipped, not failed.  The next day's run tries again.
    ConditionPathExists = "/dev/disk/by-uuid/${diskUuid}";
    RequiresMountsFor = [ "/home" "/persist" mountPoint ];
  };
}
