# VM test for modules/impermanence.nix on the real PortableSSD disk layout.
#
#   nix build .#checks.x86_64-linux.impermanence -L
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
    try:
        machine.wait_for_unit("multi-user.target")
        machine.succeed("findmnt -no OPTIONS / | grep -q 'subvol=/@root'")
        machine.succeed("findmnt -no OPTIONS /home | grep -q 'subvol=/@home'")
        machine.succeed("findmnt -no OPTIONS /var/cache/dev | grep -q 'subvol=/@dev-scratch'")
        machine.succeed("grep -qF 'thinky:${testHash}:' /etc/shadow")

        machine.succeed("touch /root-canary /etc/etc-canary /var/lib/nixos/state-canary")
        machine.succeed("touch /persist/persist-canary /home/home-canary /var/log/log-canary")
        machine.succeed("su -s /bin/sh thinky -c 'touch /var/cache/dev/thinky/cargo-target/scratch-canary'")
        machine.succeed(
            "su -s /bin/sh thinky -c '"
            "mkdir -p "
            "/home/thinky/Projects/demo/src "
            "/home/thinky/Projects/demo/target/debug "
            "/home/thinky/Projects/demo/.devenv/gc "
            "/home/thinky/Projects/demo/.direnv "
            "/home/thinky/Projects/demo/pkg/__pycache__ "
            "/home/thinky/Projects/demo/build_local "
            "/home/thinky/Projects/docs/target "
            "/home/thinky/Projects/emacs/tree-sitter "
            "/home/thinky/.cargo/registry/src "
            "/home/thinky/.ssh && "
            "touch /home/thinky/Projects/demo/Cargo.toml "
            "/home/thinky/Projects/demo/src/main.rs "
            "/home/thinky/Projects/demo/target/debug/junk "
            "/home/thinky/Projects/demo/.devenv/gc/pin "
            "/home/thinky/Projects/demo/.direnv/flake-profile-1 "
            "/home/thinky/Projects/demo/pkg/__pycache__/x.pyc "
            "/home/thinky/Projects/demo/build_local/CMakeCache.txt "
            "/home/thinky/Projects/docs/target/keep.txt "
            "/home/thinky/Projects/emacs/tree-sitter/rust.so "
            "/home/thinky/.cargo/registry/src/crate.tar "
            "/home/thinky/.ssh/id_ed25519 && "
            "ln -s /nix/store/00000000000000000000000000000000-out /home/thinky/Projects/demo/result'"
        )
        mid = machine.succeed("cat /etc/machine-id").strip()
        assert len(mid) == 32, f"bad machine-id {mid!r}"

        machine.shutdown()
        machine.start()
        machine.wait_for_unit("multi-user.target")

        # Wiped
        machine.fail("test -e /root-canary")
        machine.fail("test -e /etc/etc-canary")
        machine.fail("test -e /var/cache/dev/thinky/cargo-target/scratch-canary")
        machine.fail("test -e /home/thinky/Projects/demo/target")
        machine.fail("test -e /home/thinky/Projects/demo/.devenv")
        machine.fail("test -e /home/thinky/Projects/demo/.direnv")
        machine.fail("test -e /home/thinky/Projects/demo/pkg/__pycache__")
        machine.fail("test -e /home/thinky/Projects/demo/build_local")
        machine.fail("test -L /home/thinky/Projects/demo/result")
        machine.fail("test -e /home/thinky/.cargo/registry")
        # Kept
        machine.succeed("test -e /persist/persist-canary")
        machine.succeed("test -e /home/home-canary")
        machine.succeed("test -e /var/log/log-canary")
        machine.succeed("test -e /var/lib/nixos/state-canary")
        machine.succeed("test -e /home/thinky/Projects/demo/Cargo.toml")
        machine.succeed("test -e /home/thinky/Projects/demo/src/main.rs")
        machine.succeed("test -e /home/thinky/Projects/docs/target/keep.txt")
        machine.succeed("test -e /home/thinky/Projects/emacs/tree-sitter/rust.so")
        machine.succeed("test -e /home/thinky/.ssh/id_ed25519")
        mid2 = machine.succeed("cat /etc/machine-id").strip()
        assert mid == mid2, f"machine-id changed: {mid} -> {mid2}"
        machine.succeed("grep -qF 'thinky:${testHash}:' /etc/shadow")

        # The previous root is kept for recovery, while @dev-scratch is wiped outright.
        machine.succeed("mkdir -p /top && mount -t btrfs -o subvol=/ /dev/mapper/cryptroot /top")
        machine.succeed("ls /top/old_roots/*/root-canary")
        machine.fail("test -e /top/old_roots/*dev-scratch*")
    finally:
        # Shutdown explicitly: disko's makeDiskoTest adds booted_machine to Driver.machines
        # (a temporary list property), so Driver.__exit__ otherwise leaves QEMU running.
        try:
            machine.shutdown()
        except Exception:
            pass
  '';
}
