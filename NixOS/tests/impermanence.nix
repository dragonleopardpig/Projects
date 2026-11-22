# VM tests for modules/impermanence.nix.
#
#   nix build .#checks.x86_64-linux.impermanence -L          # PortableSSD
#   nix build .#checks.x86_64-linux.impermanence-crucial -L  # CRUCIAL-SSD
#   nix build .#checks.x86_64-linux.impermanence-x299 -L     # X299-SSD
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
#
# variant = "x299" is X299-SSD (hosts/X299-SSD/layouts.nix): CRUCIAL-SSD's
# subvolumes and swapfile, but dependency environments removed at boot like
# PortableSSD.
#
# variant = "m90" formats with hosts/M90aPro/disko.nix itself (swap partition
# with a random key, LUKS "cryptpool"), keeps environments like CRUCIAL-SSD,
# and then runs the pool extension of hosts/M90aPro/MIGRATE.md Part C on a
# second disk: m90-btrfs-migrate extend-prepare, boot the configuration with
# custom.m90Pool.secondDisk, extend, reboot -- the root must still be wiped
# and everything kept on a two-device btrfs (data single, metadata raid1).
{ pkgs, lib, inputs, variant ? "portable" }:
let
  crucial = variant == "crucial";
  m90 = variant == "m90";
  x299 = variant == "x299";
  keepEnvs = crucial || m90;
  swapSubvol = crucial || x299;
  mapper = if m90 then "cryptpool" else "cryptroot";
  testHash = "$6$impermtest$xqdvItgMcuG2UFxxfTcc254TWeSnmHuqQo5HrUmw29qdoH5Vc.kFyDQf9XIJJjd.4MSLBXVbyG75R3T1cayyh/"; # "test"
  m90Migrate = pkgs.callPackage ../packages/m90-btrfs-migrate.nix { };

  portableDisko = lib.recursiveUpdate (import ../hosts/PortableSSD/disko.nix { inherit lib; }) {
    disko.devices.disk.portable = {
      device = "/dev/vdb";
      content.partitions = {
        ESP.size = "300M";
        root.size = "3G";
        root.content.passwordFile = "/tmp/secret.key"; # written by the disko test driver
        root.content.content.subvolumes = lib.optionalAttrs swapSubvol {
          "@swap" = { mountpoint = "/swap"; mountOptions = [ "noatime" ]; };
        };
      };
    };
  };

  m90Disko = lib.recursiveUpdate (import ../hosts/M90aPro/disko.nix { inherit lib; }) {
    disko.devices.disk.m90 = {
      device = "/dev/vdb";
      content.partitions = {
        ESP.size = "300M";
        swap.size = "64M";
        root.content.passwordFile = "/tmp/secret.key";
      };
    };
    # Only to give the VM a second disk (vdc): extend-prepare partitions it.
    disko.devices.disk.pool2 = {
      type = "disk";
      device = "/dev/vdc";
      content = { type = "gpt"; partitions = { }; };
    };
  };

  diskoConfig = if m90 then m90Disko else portableDisko;

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
    ] ++ lib.optional m90 ../hosts/M90aPro/pool.nix;
    config = lib.mkMerge [
      {
        custom.impermanence.enable = true;
        custom.impermanence.device = "/dev/mapper/${mapper}";
        custom.impermanence.cleanDevEnvironments = !keepEnvs;
        users.users.thinky.isNormalUser = true;
        # Unlock without typing: systemd-cryptsetup picks this path up by name.
        boot.initrd.systemd.contents."/etc/cryptsetup-keys.d/${mapper}.key".source =
          pkgs.writeText "luks-test-key" "secretsecret";
      }
      (lib.mkIf keepEnvs {
        # Same disk, impermanence off: the guard must refuse to switch into it.
        specialisation.no-impermanence.configuration = {
          custom.impermanence.enable = lib.mkForce false;
        };
      })
      (lib.mkIf swapSubvol {
        swapDevices = [ { device = "/swap/swapfile"; size = 64; } ];
      })
      (lib.mkIf m90 {
        environment.systemPackages = [ m90Migrate ];
        boot.initrd.systemd.contents."/etc/cryptsetup-keys.d/cryptpool2.key".source =
          pkgs.writeText "luks-test-key" "secretsecret";
        # What `nixos-rebuild boot` with custom.m90Pool.secondDisk = true gives.
        specialisation.pooled.configuration = {
          custom.m90Pool.secondDisk = true;
        };
      })
    ];
  };

  postDisko = ''
    machine.succeed("mkdir -p /mnt/persist/passwords")
    machine.succeed("echo '${testHash}' > /mnt/persist/passwords/thinky")
    machine.succeed("cp /mnt/persist/passwords/thinky /mnt/persist/passwords/root")
    machine.succeed("chmod 600 /mnt/persist/passwords/*")
  '';

  extraTestScript = ''
    swap_subvol = ${if swapSubvol then "True" else "False"}
    m90 = ${if m90 then "True" else "False"}
    keep_envs = ${if keepEnvs then "True" else "False"}
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

        if swap_subvol:
            machine.succeed("swapon --show=NAME --noheadings | grep -qx /swap/swapfile")
        if m90:
            # The swap partition, under a fresh random key.
            machine.succeed("swapon --show=TYPE --noheadings | grep -qx partition")
            machine.succeed("test \"$(lsblk -no TYPE $(swapon --show=NAME --noheadings))\" = crypt")
        if keep_envs:
            # Environments kept; only the stale devenv shell script is pruned.
            for kept in ${pyList environments}:
                machine.succeed(f"test -e {kept}")
            machine.succeed("test -e /home/thinky/Projects/demo/.devenv/state/venv/bin/python")
            machine.succeed("test -e /home/thinky/Projects/demo/.devenv/shell-new.sh")
            machine.fail("test -e /home/thinky/Projects/demo/.devenv/shell-old.sh")
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
        machine.succeed("mkdir -p /top && mount -t btrfs -o subvol=/ /dev/mapper/${mapper} /top")
        machine.succeed("ls /top/old_roots/*/root-canary")
        machine.fail("ls /top/old_roots/*/tmp/tmp-canary")
        machine.fail("test -e /top/old_roots/*dev-scratch*")
        machine.succeed("umount /top")

        if m90:
            # MIGRATE.md Part C on the second disk (vdb once booted: the test
            # runner's own disk is gone, so vdb/vdc became vda/vdb).  /tmp is wiped at
            # every boot, so the key file is written again where it is needed.
            env = ("M90_TARGET=/dev/vda M90_SECOND=/dev/vdb M90_KEY_FILE=/tmp/pool.key M90_YES=1 "
                   "M90_LUKS_ARGS='--pbkdf pbkdf2 --pbkdf-force-iterations 1000'")
            def migrate(phase):
                return machine.succeed(f"{env} m90-btrfs-migrate {phase} 2>&1")
            def migrate_fails(phase):
                return machine.fail(f"{env} m90-btrfs-migrate {phase} 2>&1")
            def pool_devices():
                return int(machine.succeed("btrfs filesystem show / | grep -c devid").strip())

            machine.succeed("printf secretsecret > /tmp/pool.key")
            out = migrate_fails("extend")
            assert "does not unlock the second disk at boot" in out, out
            # A passphrase that is not the pool's is refused (boot would ask twice).
            machine.succeed("printf wrongwrong > /tmp/wrong.key")
            out = machine.fail(f"{env} M90_KEY_FILE=/tmp/wrong.key m90-btrfs-migrate extend-prepare 2>&1")
            assert "not the pool's" in out, out
            machine.succeed("test \"$(lsblk -nro NAME /dev/vdb | wc -l)\" = 1")  # still no partition

            migrate("extend-prepare")
            machine.succeed("test \"$(readlink -f /dev/disk/by-partlabel/m90-pool2)\" = /dev/vdb1")
            machine.succeed("cryptsetup isLuks /dev/vdb1")
            assert "ran already" in migrate_fails("extend-prepare")
            assert pool_devices() == 1

            # `nixos-rebuild boot` with custom.m90Pool.secondDisk = true, then reboot.
            # Done by hand here: this VM's /nix/store is the host's over 9p,
            # where nix-env (also used by the boot-loader installer) cannot take
            # ownership of it.  So: the profile generation link, and systemd-boot's
            # default set to the boot entry that already exists for the configuration.
            pooled = machine.succeed("readlink -f /run/current-system/specialisation/pooled").strip()
            machine.succeed(f"ln -sfn {pooled} /nix/var/nix/profiles/system-99-link")
            machine.succeed("ln -sfn system-99-link /nix/var/nix/profiles/system")
            entry = machine.succeed(f"grep -l '{pooled}/init' /boot/loader/entries/*.conf | head -1").strip()
            assert entry, machine.succeed("ls /boot/loader/entries")
            machine.succeed(f"sed -i '/^default /d' /boot/loader/loader.conf && echo 'default {entry.split('/')[-1]}' >> /boot/loader/loader.conf")
            machine.shutdown()
            machine.start()
            machine.wait_for_unit("multi-user.target")
            machine.succeed("test -e /dev/mapper/cryptpool2")
            machine.succeed("test -e /etc/m90-pool/second-disk")
            assert pool_devices() == 1  # unlocked, not yet in the pool

            migrate("extend")
            assert pool_devices() == 2
            df = machine.succeed("btrfs filesystem df /")
            for want in ["Data, single", "Metadata, RAID1", "System, RAID1"]:
                assert want in df, df
            assert "in the pool already" in migrate("extend")
            machine.succeed("touch /root-canary2 /home/home-canary2 /persist/persist-canary2")

            machine.shutdown()
            machine.start()
            machine.wait_for_unit("multi-user.target")
            assert pool_devices() == 2
            machine.fail("test -e /root-canary2")
            machine.succeed("test -e /home/home-canary2")
            machine.succeed("test -e /persist/persist-canary2")
            machine.succeed("test -e /home/home-canary")
            machine.succeed("test -e /home/thinky/.ssh/id_ed25519")
            machine.succeed("test \"$(cat /etc/machine-id)\" = " + mid)
            machine.succeed("grep -qF 'thinky:${testHash}:' /etc/shadow")
            machine.succeed("findmnt -no OPTIONS / | grep -q 'subvol=/@root'")
            machine.succeed("swapon --show=TYPE --noheadings | grep -qx partition")
    finally:
        # Shutdown explicitly: disko's makeDiskoTest adds booted_machine to Driver.machines
        # (a temporary list property), so Driver.__exit__ otherwise leaves QEMU running.
        try:
            machine.shutdown()
        except Exception:
            pass
  '';
}
