# The former X299 clone now uses the same hardware-neutral boot policy as the
# PortableSSD host.  Its own hardware-configuration.nix retains this Buffalo
# drive's LUKS and EFI UUIDs.
{ ... }:
{
  imports = [
    ./hardware-configuration.nix
    ../universal-boot.nix
  ];

  networking.hostName = "X299-SSD";
}
