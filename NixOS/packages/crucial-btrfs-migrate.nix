# crucial-btrfs-migrate: one-time ext4 -> btrfs (impermanence) migration of
# CRUCIAL-SSD, run from PortableSSD.  See hosts/Crucial-SSD/MIGRATE.md.
# nix-env and nixos-enter come from the running NixOS system on purpose: the
# same flake lock gives the same Nix as the store being migrated.
{
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
  rsync,
  util-linux,
}:
writeShellApplication {
  name = "crucial-btrfs-migrate";
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
    rsync
    util-linux
  ];
  text = builtins.readFile ../scripts/crucial-btrfs-migrate.sh;
}
