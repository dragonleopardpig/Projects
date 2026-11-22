# x299-btrfs-migrate: one-time ext4 -> btrfs (impermanence) migration of X299-SSD,
# with CRUCIAL-SSD's partition layout, run from M90aPro with the disk plugged in.
# See hosts/X299-SSD/MIGRATE.md.  nix, nix-env and nixos-enter come from the running
# NixOS system on purpose (same flake lock, same Nix).
{
  lib,
  writeShellApplication,
  btrfs-progs,
  coreutils,
  cryptsetup,
  dosfstools,
  e2fsprogs,
  findutils,
  gawk,
  gnugrep,
  gnused,
  gnutar,
  gptfdisk,
  procps,
  python3,
  rsync,
  util-linux,
}:
writeShellApplication {
  name = "x299-btrfs-migrate";
  runtimeInputs = [
    btrfs-progs
    coreutils
    cryptsetup
    dosfstools
    e2fsprogs
    findutils
    gawk
    gnugrep
    gnused
    gnutar
    gptfdisk
    procps
    python3
    rsync
    util-linux
  ];
  runtimeEnv = {
    # What the boot sweep would delete is left out of the copy.
    X299_SWEEP = "${../modules/impermanence-clean-dev.py}";
    X299_SWEEP_EXCLUDES = "${../scripts/sweep-excludes.py}";
  };
  text = builtins.readFile ../scripts/x299-btrfs-migrate.sh;
  meta.platforms = lib.platforms.linux;
}
