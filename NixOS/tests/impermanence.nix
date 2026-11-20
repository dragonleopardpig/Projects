# VM tests for modules/impermanence.nix.
#
#   nix build .#checks.x86_64-linux.impermanence -L          # PortableSSD
#   nix build .#checks.x86_64-linux.impermanence-crucial -L  # CRUCIAL-SSD
#
# Formats a virtual disk with hosts/PortableSSD/disko.nix (partitions shrunk
# to fit a 4 GiB test disk), installs a minimal system with the impermanence
# module, boots it twice, and checks that / and /tmp were wiped while /persist,
# /home, /var/log, /etc/machine-id and the password hash survived.
#
# variant = "crucial" uses the CRUCIAL-SSD settings (hosts/Crucial-SSD/
# layouts.nix): an extra @swap subvolume with a swapfile, and dependency
# environments (.devenv/.direnv/.venv/node_modules) kept across boots.  It also
# checks the pre-switch guard refuses a configuration that does not match the
# running root.
{ pkgs, lib, inputs, variant ? "portable" }:
let
  crucial = variant == "crucial";
  testHash = "$6$impermtest$xqdvItgMcuG2UFxxfTcc254TWeSnmHuqQo5HrUmw29qdoH5Vc.kFyDQf9XIJJjd.4MSLBXVbyG75R3T1cayyh/"; # "test"

  diskoConfig = lib.recursiveUpdate (import ../hosts/PortableSSD/disko.nix { inherit lib; }) {
    disko.devices.disk.portable = {
      device = "/dev/vdb";
      content.partitions = {
        ESP.size = "300M";
        root.size = "3G";
        root.content.passwordFile = "/tmp/secret.key"; # written by the disko test driver
        root.content.content.subvolumes = lib.optionalAttrs crucial {
          "@swap" = { mountpoint = "/swap"; mountOptions = [ "noatime" ]; };
        };
      };
    };
  };

  # Paths the boot sweep removes on both hosts, and the environments that only
  # PortableSSD removes.
  wipedEverywhere = [
    "/home/thinky/Projects/demo/target"
    "/home/thinky/Projects/demo/pkg/__pycache__"
    "/home/thinky/Projects/demo/build_local"
    "/home/thinky/.cargo/registry"
  ];
  environments = [
    "/home/thinky/Projects/demo/.devenv"
    "/home/thinky/Projects/demo/.direnv"
    "/home/thinky/Projects/demo/.venv"
  ];
  pyList = paths: "[" + lib.concatMapStringsSep ", " (p: "\"${p}\"") paths + "]";
in
inputs.disko.lib.testLib.makeDiskoTest {
  inherit pkgs;
  name = "${variant}-ssd-impermanence";
  disko-config = diskoConfig;

  extraSystemConfig = {
    imports = [
      inputs.impermanence.nixosModules.impermanence
      ../modules/impermanence.nix
    ];
    custom.impermanence.enable = true;
    custom.impermanence.cleanDevEnvironments = !crucial;
    boot.initrd.systemd.enable = true;
    users.users.thinky.isNormalUser = true;
    # Unlock without typing: systemd-cryptsetup picks this path up by name.
    boot.initrd.systemd.contents."/etc/cryptsetup-keys.d/cryptroot.key".source =
      pkgs.writeText "luks-test-key" "secretsecret";
  } // lib.optionalAttrs crucial {
    swapDevices = [ { device = "/swap/swapfile"; size = 64; } ];
    # Same disk, impermanence off: the guard must refuse to switch into it.
    specialisation.no-impermanence.configuration = {
      custom.impermanence.enable = lib.mkForce false;
    };
  };

  postDisko = ''
    machine.succeed("mkdir -p /mnt/persist/passwords")
    machine.succeed("echo '${testHash}' > /mnt/persist/passwords/thinky")
    machine.succeed("cp /mnt/persist/passwords/thinky /mnt/persist/passwords/root")
    machine.succeed("chmod 600 /mnt/persist/passwords/*")
  '';

  extraTestScript = ''
    crucial = ${if crucial then "True" else "False"}
    try:
        machine.wait_for_unit("multi-user.target")
        machine.succeed("findmnt -no OPTIONS / | grep -q 'subvol=/@root'")
        machine.succeed("findmnt -no OPTIONS /home | grep -q 'subvol=/@home'")
        machine.succeed("findmnt -no OPTIONS /tmp | grep -q 'subvol=/@tmp'")
        machine.succeed("test \"$(stat -c %a /tmp)\" = 1777")
        machine.succeed("findmnt -no OPTIONS /var/cache/dev | grep -q 'subvol=/@dev-scratch'")
        machine.succeed("grep -qF 'thinky:${testHash}:' /etc/shadow")
        machine.succeed("test -e /etc/systemd/user/trash-age.timer")

        # Build intermediates go to the wiped scratch volume, one dir per
        # workspace; final binaries stay in ./target.  The literal braces are
        # cargo's template, so they must survive the session environment.
        build_dir = machine.succeed("su - thinky -c 'printenv CARGO_BUILD_BUILD_DIR'").strip()
        assert build_dir == "/var/cache/dev/thinky/cargo-build/{workspace-path-hash}", build_dir
        machine.fail("su - thinky -c 'printenv CARGO_TARGET_DIR'")

        # The running root matches this configuration, so the guard passes.
        machine.succeed("/run/current-system/bin/switch-to-configuration check")

        machine.succeed("touch /root-canary /etc/etc-canary /var/lib/nixos/state-canary /tmp/tmp-canary")
        machine.succeed("touch /persist/persist-canary /home/home-canary /var/log/log-canary")
        machine.succeed("su -s /bin/sh thinky -c 'touch /var/cache/dev/thinky/cargo-build/scratch-canary'")
        machine.succeed(
            "su -s /bin/sh thinky -c '"
            "mkdir -p "
            "/home/thinky/Projects/demo/src "
            "/home/thinky/Projects/demo/target/debug "
            "/home/thinky/Projects/demo/.devenv/gc "
            "/home/thinky/Projects/demo/.devenv/state/venv/bin "
            "/home/thinky/Projects/demo/.direnv "
            "/home/thinky/Projects/demo/.venv "
            "/home/thinky/Projects/demo/pkg/__pycache__ "
            "/home/thinky/Projects/demo/build_local "
            "/home/thinky/Projects/docs/target "
            "/home/thinky/Projects/emacs/tree-sitter "
            "/home/thinky/Projects/org/.ob-jupyter "
            "/home/thinky/Projects/raypier/test "
            "/home/thinky/.cargo/registry/src "
            "/home/thinky/.local/share/uv/tools/llm/bin "
            "/home/thinky/.local/share/Trash/files "
            "/home/thinky/.ssh && "
            "touch /home/thinky/Projects/demo/Cargo.toml "
            "/home/thinky/Projects/demo/src/main.rs "
            "/home/thinky/Projects/demo/target/debug/junk "
            "/home/thinky/Projects/demo/.devenv/gc/pin "
            "/home/thinky/Projects/demo/.devenv/state/venv/bin/python "
            "/home/thinky/Projects/demo/.direnv/flake-profile-1 "
            "/home/thinky/Projects/demo/.venv/pyvenv.cfg "
            "/home/thinky/Projects/demo/pkg/__pycache__/x.pyc "
            "/home/thinky/Projects/demo/build_local/CMakeCache.txt "
            "/home/thinky/Projects/docs/target/keep.txt "
            "/home/thinky/Projects/emacs/tree-sitter/rust.so "
            "/home/thinky/Projects/org/.ob-jupyter/plot.png "
            "/home/thinky/Projects/raypier/test/tracked.pyc "
            "/home/thinky/.cargo/registry/src/crate.tar "
            "/home/thinky/.local/share/uv/tools/llm/bin/llm "
            "/home/thinky/.local/share/Trash/files/report.pdf "
            "/home/thinky/.ssh/id_ed25519 && "
            "touch -d 2026-01-01 /home/thinky/Projects/demo/.devenv/shell-old.sh && "
            "touch -d 2026-02-01 /home/thinky/Projects/demo/.devenv/shell-new.sh && "
            "ln -s /nix/store/00000000000000000000000000000000-out /home/thinky/Projects/demo/result'"
        )
        mid = machine.succeed("cat /etc/machine-id").strip()
        assert len(mid) == 32, f"bad machine-id {mid!r}"

        machine.shutdown()
        machine.start()
        machine.wait_for_unit("multi-user.target")
        machine.succeed("systemctl is-active impermanence-clean-dev.service || systemctl show -p Result impermanence-clean-dev.service | grep -q success")

        # Wiped
        machine.fail("test -e /root-canary")
        machine.fail("test -e /etc/etc-canary")
        machine.fail("test -e /tmp/tmp-canary")
        machine.succeed("test \"$(stat -c %a /tmp)\" = 1777")
        machine.fail("test -e /var/cache/dev/thinky/cargo-build/scratch-canary")
        for gone in ${pyList wipedEverywhere}:
            machine.fail(f"test -e {gone}")
        machine.fail("test -L /home/thinky/Projects/demo/result")
        # Kept
        machine.succeed("test -e /persist/persist-canary")
        machine.succeed("test -e /home/home-canary")
        machine.succeed("test -e /var/log/log-canary")
        machine.succeed("test -e /var/lib/nixos/state-canary")
        machine.succeed("test -e /home/thinky/Projects/demo/Cargo.toml")
        machine.succeed("test -e /home/thinky/Projects/demo/src/main.rs")
        machine.succeed("test -e /home/thinky/Projects/docs/target/keep.txt")
        machine.succeed("test -e /home/thinky/Projects/emacs/tree-sitter/rust.so")
        machine.succeed("test -e /home/thinky/Projects/org/.ob-jupyter/plot.png")
        machine.succeed("test -e /home/thinky/Projects/raypier/test/tracked.pyc")
        machine.succeed("test -e /home/thinky/.local/share/uv/tools/llm/bin/llm")
        machine.succeed("test -e /home/thinky/.local/share/Trash/files/report.pdf")
        machine.succeed("test -e /home/thinky/.ssh/id_ed25519")
        mid2 = machine.succeed("cat /etc/machine-id").strip()
        assert mid == mid2, f"machine-id changed: {mid} -> {mid2}"
        machine.succeed("grep -qF 'thinky:${testHash}:' /etc/shadow")

        # Only at boot: neither a later start of the unit nor a switch may clean the
        # running session (11-20: every nixos-rebuild switch re-ran it).
        later = "/home/thinky/Projects/demo/later/__pycache__"
        machine.succeed(f"mkdir -p {later} && touch {later}/x.pyc && chown -R thinky:users /home/thinky/Projects/demo/later")
        runs = "journalctl -b -u impermanence-clean-dev.service -o cat | grep -c 'clean-dev-cache:' || true"
        assert machine.succeed(runs).strip() == "1", machine.succeed(runs)
        machine.succeed("systemctl is-active impermanence-clean-dev.service")
        machine.succeed("systemctl start impermanence-clean-dev.service")
        machine.succeed("/run/current-system/bin/switch-to-configuration test")
        machine.succeed(f"test -e {later}/x.pyc")
        assert machine.succeed(runs).strip() == "1", machine.succeed(runs)

        if crucial:
            # Environments kept; only the stale devenv shell script is pruned.
            for kept in ${pyList environments}:
                machine.succeed(f"test -e {kept}")
            machine.succeed("test -e /home/thinky/Projects/demo/.devenv/state/venv/bin/python")
            machine.succeed("test -e /home/thinky/Projects/demo/.devenv/shell-new.sh")
            machine.fail("test -e /home/thinky/Projects/demo/.devenv/shell-old.sh")
            machine.succeed("swapon --show=NAME --noheadings | grep -qx /swap/swapfile")
            # Impermanence off on this impermanent root: refused, unless overridden.
            spec = "/run/current-system/specialisation/no-impermanence/bin/switch-to-configuration"
            out = machine.fail(f"{spec} check 2>&1")
            assert "impermanence-layout" in out, out
            machine.succeed(f"NIXOS_NO_CHECK=1 {spec} check")
        else:
            for gone in ${pyList environments}:
                machine.fail(f"test -e {gone}")

        # The previous root is kept for recovery; @tmp and @dev-scratch are
        # deleted outright, so neither shows up in old_roots.
        machine.succeed("mkdir -p /top && mount -t btrfs -o subvol=/ /dev/mapper/cryptroot /top")
        machine.succeed("ls /top/old_roots/*/root-canary")
        machine.fail("ls /top/old_roots/*/tmp/tmp-canary")
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
