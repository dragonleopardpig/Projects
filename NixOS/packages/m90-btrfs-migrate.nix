# m90-btrfs-migrate: M90aPro ext4 -> impermanent btrfs on its other SSD, then
# both SSDs as one pool.  Run from the PortableSSD (prepare..install) and on the
# btrfs M90aPro (extend-prepare, extend).  See hosts/M90aPro/MIGRATE.md.
# nix, nix-env, nixos-enter and udevadm come from the running NixOS system on
# purpose: the same flake lock gives the same Nix as the store being written.
{
  writeShellApplication,
  btrfs-progs,
  coreutils,
  cryptsetup,
  e2fsprogs,
  findutils,
  gawk,
  gnugrep,
  gnused,
  gptfdisk,
  rsync,
  util-linux,
}:
writeShellApplication {
  name = "m90-btrfs-migrate";
  runtimeInputs = [
    btrfs-progs
    coreutils
    cryptsetup
    e2fsprogs
    findutils
    gawk
    gnugrep
    gnused
    gptfdisk
    rsync
    util-linux
  ];
  text = builtins.readFile ../scripts/m90-btrfs-migrate.sh;
}
