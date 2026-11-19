# VM rehearsal of scripts/crucial-btrfs-migrate.sh on a virtual disk shaped
# like CRUCIAL-SSD's (ESP, LUKS+ext4 root, empty FAT32 CRUCIALDATA):
#
#   nix build .#checks.x86_64-linux.crucial-migration -L
#
# Runs every phase the way MIGRATE.md does (stage, format, copy, install), then
# rollback, then the whole way again up to release-stage, and checks ownership,
# hard links, xattrs, excludes, persisted state, password hashes, the system
# profile and the boot-loader call.  GRUB itself is replaced by a stub
# switch-to-configuration; the real one is exercised by the impermanence tests.
{ pkgs, lib }:
let
  migrate = pkgs.callPackage ../packages/crucial-btrfs-migrate.nix { };
  luksUuid = "77595ddf-4ac1-4521-a712-25f2dfaa02c3";
  hash = "$6$impermtest$xqdvItgMcuG2UFxxfTcc254TWeSnmHuqQo5HrUmw29qdoH5Vc.kFyDQf9XIJJjd.4MSLBXVbyG75R3T1cayyh/";

  # What `install` puts in the profile and runs inside nixos-enter.
  fakeSystem = pkgs.runCommand "nixos-system-crucial-rehearsal" { } ''
    mkdir -p $out/bin $out/sw/bin
    ln -s ${pkgs.bash}/bin/bash $out/sw/bin/bash
    printf '#!${pkgs.runtimeShell}\nexit 0\n' > $out/activate
    printf '#!${pkgs.runtimeShell}\necho "$1 $NIXOS_INSTALL_BOOTLOADER" > /boot/stc-called\n' \
      > $out/bin/switch-to-configuration
    chmod +x $out/activate $out/bin/switch-to-configuration
  '';
in
pkgs.testers.runNixOSTest {
  name = "crucial-btrfs-migration";

  nodes.machine = { pkgs, ... }: {
    virtualisation.emptyDiskImages = [ 6144 ]; # /dev/vdb
    virtualisation.memorySize = 2048;
    boot.supportedFilesystems = [ "btrfs" "vfat" ];
    # The tool carries its own; these set up and inspect the test disk.
    environment.systemPackages = with pkgs; [
      migrate gptfdisk attr cryptsetup e2fsprogs btrfs-progs dosfstools
    ];
    system.extraDependencies = [ fakeSystem ];
    nix.settings.experimental-features = [ "nix-command" ];
  };

  testScript = ''
    env = "CRUCIAL_KEY_FILE=/tmp/key CRUCIAL_YES=1"
    def migrate(phase):
        return machine.succeed(f"{env} crucial-btrfs-migrate {phase} 2>&1")
    def migrate_fails(phase):
        return machine.fail(f"{env} crucial-btrfs-migrate {phase} 2>&1")
    def populate_old_root():
        machine.succeed(
            "cryptsetup open /dev/vdb2 old --key-file /tmp/key",
            "mkfs.ext4 -q -F /dev/mapper/old",
            "mkdir -p /mnt/old && mount /dev/mapper/old /mnt/old",
            "nix copy --no-check-sigs --to /mnt/old ${fakeSystem}",
            "mkdir -p /mnt/old/home/thinky/.local/state/crucial-migration",
            "ln -s ${fakeSystem} /mnt/old/home/thinky/.local/state/crucial-migration/system",
            # No final newline on purpose: the last entry must still be copied.
            "printf 'dir /var/lib/nixos\\ndir /etc/NetworkManager/system-connections\\n"
            "dir /var/lib/absent\\nfile /etc/machine-id' "
            "> /mnt/old/home/thinky/.local/state/crucial-migration/persist.txt",
            "mkdir -p /mnt/old/var/lib/nixos /mnt/old/etc/NetworkManager/system-connections",
            "echo 'thinky:1000' > /mnt/old/var/lib/nixos/uid-map",
            "echo wifi > /mnt/old/etc/NetworkManager/system-connections/home.nmconnection",
            "chmod 600 /mnt/old/etc/NetworkManager/system-connections/home.nmconnection",
            "echo 0123456789abcdef0123456789abcdef > /mnt/old/etc/machine-id",
            "printf 'root:!:1::::::\\nthinky:${hash}:1::::::\\n' > /mnt/old/etc/shadow",
            "mkdir -p /mnt/old/home/thinky/Projects/strata/target /mnt/old/home/thinky/Projects/strata/src",
            "echo keep > /mnt/old/home/thinky/Projects/keep.txt",
            "setfattr -n user.kept -v yes /mnt/old/home/thinky/Projects/keep.txt",
            "ln /mnt/old/home/thinky/Projects/keep.txt /mnt/old/home/thinky/Projects/keep-link.txt",
            "echo junk > /mnt/old/home/thinky/Projects/strata/target/junk",
            "echo 'fn main(){}' > /mnt/old/home/thinky/Projects/strata/src/main.rs",
            "chown -R 1000:100 /mnt/old/home/thinky",
            "umount /mnt/old && cryptsetup close old",
        )

    machine.wait_for_unit("multi-user.target")
    machine.succeed(
        "printf secretsecret > /tmp/key",
        "sgdisk -n1:0:+64M -t1:EF00 -n2:0:+2G -t2:8300 -n3:0:0 -t3:0700 /dev/vdb",
        "udevadm settle",
        "mkfs.vfat -i 42F5D6BF /dev/vdb1",
        "cryptsetup luksFormat --batch-mode --type luks2 --uuid ${luksUuid}"
        " --pbkdf pbkdf2 --pbkdf-force-iterations 1000 /dev/vdb2 /tmp/key",
        "mkfs.vfat -F 32 -n CRUCIALDATA /dev/vdb3",
        "udevadm settle",
    )
    populate_old_root()

    with subtest("check identifies the disk; dry runs change nothing"):
        out = migrate("check")
        assert "/dev/vdb2" in out and "inside    : ext4" in out, out
        out = migrate("--dry-run stage")
        assert "[dry-run] mkfs.ext4" in out, out
        machine.succeed("test \"$(blkid -s LABEL -o value /dev/vdb3)\" = CRUCIALDATA")

    with subtest("stage refuses a non-empty CRUCIALDATA (bin and trash too), and copy before stage"):
        # What Windows and a desktop leave on an empty partition, as on the
        # real CRUCIALDATA; these stay for the stage below.
        machine.succeed(
            "mkdir -p /mnt/d && mount /dev/vdb3 /mnt/d",
            "mkdir -p '/mnt/d/System Volume Information' '/mnt/d/$RECYCLE.BIN/S-1-5-21-7'"
            " /mnt/d/.Trash-1000/info /mnt/d/.Trash-1000/files",
            "touch '/mnt/d/System Volume Information/WPSettings.dat' '/mnt/d/$RECYCLE.BIN/desktop.ini'"
            " '/mnt/d/$RECYCLE.BIN/S-1-5-21-7/desktop.ini'",
            "touch /mnt/d/photo.jpg /mnt/d/.Trash-1000/files/old.jpg '/mnt/d/$RECYCLE.BIN/S-1-5-21-7/$RAB12.jpg'",
            "umount /mnt/d",
        )
        out = migrate_fails("stage")
        for listed in ["photo.jpg", ".Trash-1000/files/old.jpg", "S-1-5-21-7/$RAB12.jpg"]:
            assert listed in out, out
        assert "not empty" in out and "desktop.ini" not in out and "WPSettings" not in out, out
        machine.succeed(
            "mount /dev/vdb3 /mnt/d",
            "rm /mnt/d/photo.jpg /mnt/d/.Trash-1000/files/old.jpg '/mnt/d/$RECYCLE.BIN/S-1-5-21-7/$RAB12.jpg'",
            "umount /mnt/d",
        )
        assert "has not run" in migrate_fails("copy")

    with subtest("stage: exact image + LUKS header on CRUCIAL-STAGE"):
        migrate("stage")
        machine.succeed("test \"$(blkid -s LABEL -o value /dev/vdb3)\" = CRUCIAL-STAGE")
        machine.succeed("mount -o ro /dev/vdb3 /mnt/d")
        machine.succeed("e2fsck -fn /mnt/d/crucial-root-ext4.img")
        machine.succeed("test -s /mnt/d/crucial-migration/luks-header.img")
        machine.succeed("umount /mnt/d")
        assert "already" in migrate_fails("stage")

    def check_new_layout():
        machine.succeed(
            "cryptsetup open /dev/vdb2 chk --key-file /tmp/key",
            "mkdir -p /mnt/chk && mount -o subvol=/ /dev/mapper/chk /mnt/chk",
        )
        subvols = machine.succeed("btrfs subvolume list /mnt/chk")
        for s in ["@root", "@nix", "@persist", "@home", "@swap"]:
            assert f"path {s}\n" in subvols + "\n", subvols
        h = "/mnt/chk/@home/thinky/Projects"
        machine.succeed(f"test \"$(stat -c %u:%g {h}/keep.txt)\" = 1000:100")
        machine.succeed(f"test \"$(stat -c %h {h}/keep.txt)\" = 2")
        machine.succeed(f"getfattr -n user.kept {h}/keep.txt | grep -q yes")
        machine.succeed(f"test -e {h}/strata/src/main.rs")
        machine.fail(f"test -e {h}/strata/target")
        p = "/mnt/chk/@persist"
        machine.succeed(f"grep -q thinky:1000 {p}/var/lib/nixos/uid-map")
        machine.succeed(f"test \"$(stat -c %a {p}/etc/NetworkManager/system-connections/home.nmconnection)\" = 600")
        machine.succeed(f"grep -q 0123456789abcdef {p}/etc/machine-id")
        machine.fail(f"test -e {p}/var/lib/absent")
        machine.succeed(f"grep -qxF '${hash}' {p}/passwords/thinky")
        machine.succeed(f"grep -qx '!' {p}/passwords/root")
        machine.succeed(f"test \"$(stat -c %a {p}/passwords/thinky)\" = 600")
        machine.succeed("test -e /mnt/chk/@nix/var/nix/db/db.sqlite")
        machine.succeed(
            "test \"$(readlink -f /mnt/chk/@nix/var/nix/profiles/system)\" = /mnt/chk/@nix/store/$(basename ${fakeSystem})"
            " || test \"$(readlink /mnt/chk/@nix/var/nix/profiles/$(readlink /mnt/chk/@nix/var/nix/profiles/system))\" = ${fakeSystem}"
        )
        machine.succeed("umount /mnt/chk && cryptsetup close chk")
        machine.succeed("mkdir -p /mnt/esp && mount /dev/vdb1 /mnt/esp")
        machine.succeed("grep -qx 'boot 1' /mnt/esp/stc-called && rm /mnt/esp/stc-called")
        machine.succeed("umount /mnt/esp")

    with subtest("format, copy, install"):
        migrate("format")
        migrate("copy")
        migrate("install")
        out = migrate("check")
        assert "phase install : done" in out, out
        check_new_layout()

    with subtest("release-stage refuses while the root is ext4; rollback restores ext4"):
        migrate("rollback")
        out = migrate("check")
        assert "inside    : ext4" in out, out
        machine.succeed(
            "cryptsetup open --readonly /dev/vdb2 chk --key-file /tmp/key",
            "mkdir -p /mnt/chk && mount -o ro /dev/mapper/chk /mnt/chk",
            "test -e /mnt/chk/home/thinky/Projects/strata/target/junk",
            "grep -qx keep /mnt/chk/home/thinky/Projects/keep.txt",
            "umount /mnt/chk && cryptsetup close chk",
        )
        assert "not btrfs" in migrate_fails("release-stage")

    with subtest("again after the rollback, then release the staging partition"):
        migrate("format")
        migrate("copy")
        migrate("install")
        check_new_layout()
        migrate("release-stage")
        machine.succeed("test \"$(blkid -s LABEL -o value /dev/vdb3)\" = CRUCIALDATA")
        machine.succeed("test \"$(blkid -s TYPE -o value /dev/vdb3)\" = vfat")
        machine.succeed("test \"$(sgdisk -i 3 /dev/vdb | grep -c 'EBD0A0A2-B9E5-4433-87C0-68B6B72699C7')\" = 1")
  '';
}
