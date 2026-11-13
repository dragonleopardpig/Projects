# VM test for modules/impermanence.nix on the real PortableSSD disk layout.
#
#   nix build --impure .#checks.x86_64-linux.impermanence -L
#
# Formats a virtual disk with hosts/PortableSSD/disko.nix (partitions shrunk
# to fit a 4 GiB test disk), installs a minimal system with the impermanence
# module, boots it twice, and checks that / was wiped while /persist, /home,
# /var/log, /etc/machine-id and the password hash survived.
{ pkgs, lib, inputs }:
let
  testHash = "$6$impermtest$xqdvItgMcuG2UFxxfTcc254TWeSnmHuqQo5HrUmw29qdoH5Vc.kFyDQf9XIJJjd.4MSLBXVbyG75R3T1cayyh/"; # "test"

  diskoConfig = lib.recursiveUpdate (import ../hosts/PortableSSD/disko.nix { inherit lib; }) {
    disko.devices.disk.portable = {
      device = "/dev/vdb";
      content.partitions = {
        ESP.size = "300M";
        root.size = "3G";
        root.content.passwordFile = "/tmp/secret.key"; # written by the disko test driver
      };
    };
  };
in
inputs.disko.lib.testLib.makeDiskoTest {
  inherit pkgs;
  name = "portable-ssd-impermanence";
  disko-config = diskoConfig;

  extraSystemConfig = {
    imports = [
      inputs.impermanence.nixosModules.impermanence
      ../modules/impermanence.nix
    ];
    custom.impermanence.enable = true;
    boot.initrd.systemd.enable = true;
    users.users.thinky.isNormalUser = true;
    # Unlock without typing: systemd-cryptsetup picks this path up by name.
    boot.initrd.systemd.contents."/etc/cryptsetup-keys.d/cryptroot.key".source =
      pkgs.writeText "luks-test-key" "secretsecret";
  };

  postDisko = ''
    machine.succeed("mkdir -p /mnt/persist/passwords")
    machine.succeed("echo '${testHash}' > /mnt/persist/passwords/thinky")
    machine.succeed("cp /mnt/persist/passwords/thinky /mnt/persist/passwords/root")
    machine.succeed("chmod 600 /mnt/persist/passwords/*")
  '';

  extraTestScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.succeed("findmnt -no OPTIONS / | grep -q 'subvol=/@root'")
    machine.succeed("grep -qF 'thinky:${testHash}:' /etc/shadow")

    machine.succeed("touch /root-canary /etc/etc-canary /var/lib/nixos/state-canary")
    machine.succeed("touch /persist/persist-canary /home/home-canary /var/log/log-canary")
    mid = machine.succeed("cat /etc/machine-id").strip()
    assert len(mid) == 32, f"bad machine-id {mid!r}"

    machine.shutdown()
    machine.start()
    machine.wait_for_unit("multi-user.target")

    # Wiped
    machine.fail("test -e /root-canary")
    machine.fail("test -e /etc/etc-canary")
    # Kept
    machine.succeed("test -e /persist/persist-canary")
    machine.succeed("test -e /home/home-canary")
    machine.succeed("test -e /var/log/log-canary")
    machine.succeed("test -e /var/lib/nixos/state-canary")
    mid2 = machine.succeed("cat /etc/machine-id").strip()
    assert mid == mid2, f"machine-id changed: {mid} -> {mid2}"
    machine.succeed("grep -qF 'thinky:${testHash}:' /etc/shadow")

    # The previous root is kept for recovery.
    machine.succeed("mkdir -p /top && mount -t btrfs -o subvol=/ /dev/mapper/cryptroot /top")
    machine.succeed("ls /top/old_roots/*/root-canary")
  '';
}
