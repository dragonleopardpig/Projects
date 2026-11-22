# VM rehearsal of scripts/x299-btrfs-migrate.sh on a virtual disk shaped like X299-SSD's
# (BIOS boot, ESP, LUKS+ext4 root, FAT DATA, ext4 "Virtual Windows"), with a second disk
# as the stage (Linux-Data):
#
#   nix build .#checks.x86_64-linux.x299-migration -L
#
# Starts the way the real disk is found on M90aPro (root unlocked and mounted by the
# desktop, DATA and Virtual Windows mounted), then: stage, format, copy, install and the
# checks of the new layout; rollback (old table, MBR code, BIOS boot, ESP, root back);
# a format cut short after the table was rewritten (LUKS header gone) and its rollback;
# the whole way again, and release-stage once the new root has a journal.  GRUB itself is
# replaced by a stub switch-to-configuration; the real one is exercised by the
# impermanence tests.
{ pkgs, lib }:
let
  migrate = pkgs.callPackage ../packages/x299-btrfs-migrate.nix { };
  luksUuid = "d9622547-f79a-4640-8036-b478f59bf3fd";
  vwUuid = "fe0516c1-a263-495f-b22d-ef205ead9203";
  hash = "$6$impermtest$xqdvItgMcuG2UFxxfTcc254TWeSnmHuqQo5HrUmw29qdoH5Vc.kFyDQf9XIJJjd.4MSLBXVbyG75R3T1cayyh/";

  # What `prepare` builds and `install` puts in the profile and runs inside nixos-enter.
  fakeSystem = pkgs.runCommand "nixos-system-x299-rehearsal" { } ''
    mkdir -p $out/bin $out/sw/bin
    ln -s ${pkgs.bash}/bin/bash $out/sw/bin/bash
    printf '#!${pkgs.runtimeShell}\nexit 0\n' > $out/activate
    printf '#!${pkgs.runtimeShell}\necho "$1 $NIXOS_INSTALL_BOOTLOADER" > /boot/stc-called\n' \
      > $out/bin/switch-to-configuration
    chmod +x $out/activate $out/bin/switch-to-configuration
  '';
in
pkgs.testers.runNixOSTest {
  name = "x299-btrfs-migration";

  nodes.machine = { pkgs, ... }: {
    virtualisation.emptyDiskImages = [ 4096 6144 ]; # /dev/vdb X299, /dev/vdc Linux-Data
    virtualisation.memorySize = 2048;
    boot.supportedFilesystems = [ "btrfs" "vfat" ];
    environment.systemPackages = with pkgs; [
      migrate gptfdisk attr cryptsetup e2fsprogs btrfs-progs dosfstools
    ];
    system.extraDependencies = [ fakeSystem ];
    nix.settings.experimental-features = [ "nix-command" ];
    # Linux-Data on M90aPro is an automount: findmnt lists autofs and ext4 there.
    systemd.mounts = [ { what = "/dev/vdc"; where = "/mnt/backup"; type = "ext4"; } ];
    systemd.automounts = [ { where = "/mnt/backup"; wantedBy = [ "multi-user.target" ]; } ];
  };

  testScript = ''
    stage = "/mnt/backup/x299-migration"
    env = ("X299_KEY_FILE=/dev/shm/key X299_YES=1 X299_STAGE=" + stage + " X299_ESP_MIB=64"
           " X299_LUKS_FORMAT_ARGS='--pbkdf pbkdf2 --pbkdf-force-iterations 1000'")
    fast = "--pbkdf pbkdf2 --pbkdf-force-iterations 1000"
    def migrate(phase, extra=""):
        return machine.succeed(f"{env} {extra} x299-btrfs-migrate {phase} 2>&1")
    def migrate_fails(phase, extra=""):
        return machine.fail(f"{env} {extra} x299-btrfs-migrate {phase} 2>&1")
    def sha(cmd):
        return machine.succeed(cmd + " | sha256sum").split()[0]

    machine.wait_for_unit("multi-user.target")
    machine.succeed(
        "printf secretsecret > /dev/shm/key && printf wrongwrong > /dev/shm/bad && printf secretsecret > /root/key",
        "sgdisk -n1:2048:+1M -t1:EF02 -c1:BIOS-BOOT -n2:0:+128M -t2:EF00 -c2:EFI"
        " -n3:0:+1536M -t3:8300 -c3:cryptroot -n4:0:+256M -t4:0700 -n5:0:+256M -t5:8300"
        " -c5:'Virtual Windows' /dev/vdb",
        "udevadm settle",
        # Boot code in the MBR and a GRUB core in BIOS boot: rollback must put both back.
        "printf MBRBOOTCODE | dd of=/dev/vdb bs=1 conv=notrunc status=none",
        "printf BIOSBOOTCORE | dd of=/dev/vdb1 conv=notrunc status=none",
        "mkfs.vfat -F 32 -i 0C042087 -n EFI /dev/vdb2",
        "mkdir -p /mnt/e && mount /dev/vdb2 /mnt/e && mkdir -p /mnt/e/EFI/BOOT /mnt/e/kernels",
        "echo old-grub > /mnt/e/EFI/BOOT/BOOTX64.EFI && echo k > /mnt/e/kernels/old-bzImage && umount /mnt/e",
        f"cryptsetup luksFormat --batch-mode --type luks2 --uuid ${luksUuid} {fast} /dev/vdb3 /dev/shm/key",
        "mkfs.vfat -F 32 -i 1EF410FF -n DATA /dev/vdb4",
        "mkfs.ext4 -q -L 'Virtual Windows' -U ${vwUuid} /dev/vdb5",
        "mkfs.ext4 -q -L Linux-Data /dev/vdc && ls /mnt/backup && findmnt -t autofs /mnt/backup",
        "udevadm settle",
    )
    mbr = sha("head -c 440 /dev/vdb")
    bios = sha("cat /dev/vdb1")

    # Today's root, as on X299.
    machine.succeed(
        "cryptsetup open /dev/vdb3 old --key-file /dev/shm/key && mkfs.ext4 -q /dev/mapper/old",
        "mkdir -p /mnt/old && mount /dev/mapper/old /mnt/old",
        "mkdir -p /mnt/old/var/lib/nixos /mnt/old/etc/NetworkManager/system-connections /mnt/old/tmp",
        "echo 'thinky:1000' > /mnt/old/var/lib/nixos/uid-map",
        "echo wifi > /mnt/old/etc/NetworkManager/system-connections/home.nmconnection",
        "chmod 600 /mnt/old/etc/NetworkManager/system-connections/home.nmconnection",
        "echo 0123456789abcdef0123456789abcdef > /mnt/old/etc/machine-id",
        "printf 'root:!:1::::::\\nthinky:${hash}:1::::::\\n' > /mnt/old/etc/shadow",
        "echo junk > /mnt/old/tmp/junk",
        "H=/mnt/old/home/thinky; mkdir -p $H/Projects/demo/src $H/Projects/demo/__pycache__"
        " $H/Projects/demo/.venv/bin $H/Projects/demo/node_modules/x"
        " \"$H/Projects/we[i]rd*/__pycache__\" $H/.cache/uv $H/.local/share/app"
        " $H/.local/state/nix/profiles",
        "H=/mnt/old/home/thinky; echo 'fn main(){}' > $H/Projects/demo/src/main.rs"
        " && echo c > $H/Projects/demo/__pycache__/m.pyc"
        " && echo 'home = /usr' > $H/Projects/demo/.venv/pyvenv.cfg && echo py > $H/Projects/demo/.venv/bin/python"
        " && echo '{}' > $H/Projects/demo/node_modules/.package-lock.json && echo x > $H/Projects/demo/node_modules/x/i.js"
        " && echo c > \"$H/Projects/we[i]rd*/__pycache__/w.pyc\" && echo keep > \"$H/Projects/we[i]rd*/main.py\""
        " && echo blob > $H/.cache/uv/blob && echo keep > $H/.local/share/app/data",
        "H=/mnt/old/home/thinky; echo keep > $H/Projects/keep.txt && setfattr -n user.kept -v yes $H/Projects/keep.txt"
        " && ln $H/Projects/keep.txt $H/Projects/keep-link.txt",
        # A user profile that lives only in the old store, and junk nothing refers to.
        "echo apps > /tmp/profile && echo junk > /tmp/oldjunk",
        "P=$(nix-store --store /mnt/old --add /tmp/profile) && echo $P > /tmp/profile-path"
        " && ln -s $P /mnt/old/home/thinky/.local/state/nix/profiles/profile-1-link"
        " && ln -s profile-1-link /mnt/old/home/thinky/.local/state/nix/profiles/profile",
        "nix-store --store /mnt/old --add /tmp/oldjunk > /tmp/junk-path",
        "chown -R 1000:100 /mnt/old/home/thinky",
        "umount /mnt/old && cryptsetup close old",
    )
    profile = machine.succeed("cat /tmp/profile-path").strip()
    junk = machine.succeed("cat /tmp/junk-path").strip()
    machine.fail(f"test -e {profile}")

    # What `prepare` leaves in the stage dir (it builds the real system with the flake).
    machine.succeed(
        f"mkdir -p {stage} && ln -s ${fakeSystem} {stage}/system",
        "printf 'dir /var/lib/nixos\\ndir /etc/NetworkManager/system-connections\\n"
        f"dir /var/lib/absent\\nfile /etc/machine-id' > {stage}/persist.txt",
    )

    # As found on M90aPro: unlocked + mounted by the desktop, DATA and WinApps mounted.
    def desktop_mounts():
        machine.succeed(
            "cryptsetup open /dev/vdb3 luks-${luksUuid} --key-file /dev/shm/key",
            "mkdir -p /run/media/thinky/nixos && mount /dev/mapper/luks-${luksUuid} /run/media/thinky/nixos",
            "mkdir -p /run/media/thinky/DATA '/run/media/thinky/Virtual Windows'",
            "mount /dev/vdb4 /run/media/thinky/DATA && mount /dev/vdb5 '/run/media/thinky/Virtual Windows'",
            "echo photo > /run/media/thinky/DATA/photo.jpg && echo vm > '/run/media/thinky/Virtual Windows/win.img'",
        )
    desktop_mounts()

    with subtest("check, dry run, and the refusals before anything changes"):
        out = migrate("check")
        assert "layout: old" in out and "inside    : ext4" in out, out
        out = migrate("--dry-run stage")
        assert "[dry-run]" in out, out
        machine.fail(f"test -e {stage}/stage.done")
        assert "does not unlock" in migrate_fails("stage", "X299_KEY_FILE=/dev/shm/bad")
        assert "not on tmpfs" in migrate_fails("stage", "X299_KEY_FILE=/root/key")
        assert "on the X299 disk itself" in migrate_fails("stage", "X299_STAGE=/run/media/thinky/DATA/stage")
        assert "run 'stage' first" in migrate_fails("format")
        assert "run 'format' first" in migrate_fails("copy")
        assert "nothing to roll back" in migrate_fails("rollback")
        machine.succeed("findmnt /run/media/thinky/nixos")

    with subtest("stage: GPT, first sectors, ESP files and the raw encrypted root, checksummed"):
        migrate("stage")
        machine.fail("findmnt /run/media/thinky/nixos")
        machine.fail("test -e /dev/mapper/luks-${luksUuid}")
        machine.succeed(f"test -e {stage}/stage.done && cmp {stage}/x299-cryptroot.img /dev/vdb3")
        machine.succeed(f"tar -tf {stage}/esp.tar | grep -q EFI/BOOT/BOOTX64.EFI")
        # Nothing decrypted on the stage disk.
        machine.fail(f"grep -rqa 'fn main' {stage}")
        assert "already holds a stage" in migrate_fails("stage")
        assert "never formatted" in migrate_fails("rollback")

    def check_new_layout():
        table = machine.succeed("sgdisk -p /dev/vdb")
        assert "EF02" not in table, table
        assert machine.succeed("lsblk -ndo START /dev/vdb1").strip() == "2048", table
        assert machine.succeed("lsblk -ndo START /dev/vdb2").strip() == "133120", table
        machine.succeed(
            "test \"$(blkid -s UUID -o value /dev/vdb1)\" = 0C04-2087",
            "test \"$(blkid -s UUID -o value /dev/vdb2)\" = ${luksUuid}",
            "test \"$(blkid -s LABEL -o value /dev/vdb3)\" = DATA",
            "test \"$(blkid -s UUID -o value /dev/vdb4)\" = ${vwUuid}",
            "mkdir -p /mnt/d && mount -o ro /dev/vdb3 /mnt/d && grep -qx photo /mnt/d/photo.jpg && umount /mnt/d",
            "mount -o ro /dev/vdb4 /mnt/d && grep -qx vm /mnt/d/win.img && umount /mnt/d",
            "cryptsetup open /dev/vdb2 chk --key-file /dev/shm/key",
            "mkdir -p /mnt/chk && mount -o subvol=/ /dev/mapper/chk /mnt/chk",
        )
        subvols = machine.succeed("btrfs subvolume list /mnt/chk")
        for s in ["@root", "@nix", "@persist", "@home", "@swap"]:
            assert f"path {s}\n" in subvols + "\n", subvols
        h = "/mnt/chk/@home/thinky"
        machine.succeed(f"test \"$(stat -c %u:%g {h}/Projects/keep.txt)\" = 1000:100")
        machine.succeed(f"test \"$(stat -c %h {h}/Projects/keep.txt)\" = 2")
        machine.succeed(f"getfattr -n user.kept {h}/Projects/keep.txt | grep -q yes")
        for kept in ["Projects/demo/src/main.rs", "Projects/we[i]rd*/main.py", ".local/share/app/data"]:
            machine.succeed(f"test -e '{h}/{kept}'")
        for gone in ["Projects/demo/__pycache__", "Projects/we[i]rd*/__pycache__", "Projects/demo/.venv",
                     "Projects/demo/node_modules", ".cache"]:
            machine.fail(f"test -e '{h}/{gone}'")
        p = "/mnt/chk/@persist"
        machine.succeed(f"grep -q thinky:1000 {p}/var/lib/nixos/uid-map")
        machine.succeed(f"test \"$(stat -c %a {p}/etc/NetworkManager/system-connections/home.nmconnection)\" = 600")
        machine.succeed(f"grep -q 0123456789abcdef {p}/etc/machine-id")
        machine.fail(f"test -e {p}/var/lib/absent")
        machine.fail("test -e /mnt/chk/@root/tmp/junk")
        machine.succeed(f"grep -qxF '${hash}' {p}/passwords/thinky")
        machine.succeed(f"grep -qx '!' {p}/passwords/root")
        machine.succeed(f"test \"$(stat -c %a {p}/passwords/thinky)\" = 600")
        # The new store: the system and the user's profile, registered; not the old junk.
        machine.succeed("mkdir -p /mnt/nchk/nix && mount -o subvol=@nix /dev/mapper/chk /mnt/nchk/nix")
        machine.succeed("nix path-info --store local?root=/mnt/nchk ${fakeSystem}")
        machine.succeed(f"nix path-info --store local?root=/mnt/nchk {profile}")
        machine.fail(f"test -e /mnt/nchk{junk}")
        machine.succeed(
            "test \"$(readlink /mnt/nchk/nix/var/nix/gcroots/auto/x299-*)\""
            " = /home/thinky/.local/state/nix/profiles/profile-1-link"
        )
        machine.succeed(
            "test \"$(readlink /mnt/nchk/nix/var/nix/profiles/$(readlink /mnt/nchk/nix/var/nix/profiles/system))\" = ${fakeSystem}"
        )
        machine.succeed("umount /mnt/nchk/nix && umount /mnt/chk && cryptsetup close chk")
        machine.succeed("mkdir -p /mnt/esp && mount /dev/vdb1 /mnt/esp")
        machine.succeed("grep -qx 'boot 1' /mnt/esp/stc-called && rm /mnt/esp/stc-called")
        machine.fail("test -e /mnt/esp/EFI/BOOT/BOOTX64.EFI")
        machine.succeed("umount /mnt/esp")

    def check_old_layout():
        table = machine.succeed("sgdisk -p /dev/vdb")
        assert "EF02" in table, table
        assert sha("head -c 440 /dev/vdb") == mbr
        assert sha("cat /dev/vdb1") == bios
        machine.succeed(
            f"cmp {stage}/x299-cryptroot.img /dev/vdb3",
            "test \"$(blkid -s UUID -o value /dev/vdb2)\" = 0C04-2087",
            "mkdir -p /mnt/e && mount -o ro /dev/vdb2 /mnt/e && grep -qx old-grub /mnt/e/EFI/BOOT/BOOTX64.EFI && umount /mnt/e",
            "test \"$(blkid -s LABEL -o value /dev/vdb4)\" = DATA",
            "test \"$(blkid -s UUID -o value /dev/vdb5)\" = ${vwUuid}",
            "mount -o ro /dev/vdb4 /mnt/e && grep -qx photo /mnt/e/photo.jpg && umount /mnt/e",
            "cryptsetup open --readonly /dev/vdb3 chk --key-file /dev/shm/key",
            "mount -o ro /dev/mapper/chk /mnt/e && test -e /mnt/e/home/thinky/Projects/demo/.venv/bin/python"
            " && umount /mnt/e && cryptsetup close chk",
        )

    with subtest("format: CRUCIAL-style table, DATA and WinApps renumbered, untouched"):
        machine.succeed("mount /dev/vdb4 /run/media/thinky/DATA")  # grabbed again by the desktop
        migrate("format")
        machine.fail("findmnt /run/media/thinky/DATA")
        assert "layout: new" in migrate("check")
        assert "already formatted" in migrate_fails("format")

    with subtest("copy and install"):
        migrate("copy")
        migrate("install")
        check_new_layout()
        assert "has not booted" in migrate_fails("release-stage")

    with subtest("rollback: old table, MBR code, BIOS boot, ESP and root back"):
        migrate("rollback")
        check_old_layout()
        assert "layout: old" in migrate("check")

    with subtest("a format cut short after the table was rewritten, then rollback"):
        migrate("format")
        machine.succeed("wipefs -a /dev/vdb2 && udevadm settle")
        assert "layout: broken" in migrate("check")
        migrate("rollback")
        check_old_layout()

    with subtest("the whole way again, then release the stage once X299 has booted it"):
        migrate("format")
        migrate("copy")
        migrate("install")
        check_new_layout()
        # What the first boot writes: a journal on the persisted /var/log.
        machine.succeed(
            "cryptsetup open /dev/vdb2 chk --key-file /dev/shm/key && mount -o subvol=@persist /dev/mapper/chk /mnt/chk",
            "mkdir -p /mnt/chk/var/log/journal/m && touch /mnt/chk/var/log/journal/m/system.journal",
            "umount /mnt/chk && cryptsetup close chk",
        )
        migrate("release-stage")
        machine.fail(f"test -e {stage}")
  '';
}
