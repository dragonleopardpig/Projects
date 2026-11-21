# The second member of the M90aPro btrfs pool (hosts/M90aPro/MIGRATE.md, Part C).
#
# Turned on only after `m90-btrfs-migrate extend-prepare` has made the LUKS
# partition "m90-pool2" on the old system disk, and BEFORE `extend` adds it to
# the filesystem: from the first boot after that, initrd unlocks it (same
# passphrase, typed once), so no boot can meet a pool member it cannot open.
#
# The pool keeps data "single" (both disks' space, no mirror) and metadata
# "raid1": if one SSD dies the pool still mounts with `-o degraded,ro` to rescue
# the files that were on the other one.  Backups stay sync-projects.
{ config, lib, ... }:
let
  cfg = config.custom.m90Pool;
in
{
  options.custom.m90Pool.secondDisk = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Unlock the second pool member (partlabel m90-pool2) as /dev/mapper/cryptpool2 in initrd.";
  };

  config = lib.mkIf cfg.secondDisk {
    boot.initrd.luks.devices.cryptpool2 = {
      device = "/dev/disk/by-partlabel/m90-pool2";
      allowDiscards = true;
    };
    # `m90-btrfs-migrate extend` reads this to know the running system unlocks
    # the second disk at boot, i.e. that adding it to the pool is safe.
    environment.etc."m90-pool/second-disk".text = "/dev/disk/by-partlabel/m90-pool2\n";
  };
}
