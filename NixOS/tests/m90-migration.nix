# VM rehearsal of scripts/m90-btrfs-migrate.sh (hosts/M90aPro/MIGRATE.md):
#
#   nix build .#checks.x86_64-linux.m90-migration -L
#
# Two disks shaped like the M90aPro's: the old system (ESP + LUKS -> ext4 with
# canaries) and the emptied Windows data disk (Microsoft reserved + NTFS).  The
# new disk is formatted by the very script disko builds from
# hosts/M90aPro/disko.nix (sizes shrunk, device /dev/vdc).  Runs check, the
# refusals, format, copy and install, checks the result (ownership, hard links,
# xattrs, cargo target/ skipped, persisted state, passwords, store, profile, the
# boot-loader call) and that the old disk was never written.  GRUB is replaced
# by a stub switch-to-configuration.  The pool extension (Part C) runs in
# tests/impermanence.nix, variant "m90".
{ pkgs, lib, inputs }:
let
  migrate = pkgs.callPackage ../packages/m90-btrfs-migrate.nix { };
  luksUuid = "e4268bbb-c627-4904-b67f-8a76fe0cbf52";
  hash = "$6$impermtest$xqdvItgMcuG2UFxxfTcc254TWeSnmHuqQo5HrUmw29qdoH5Vc.kFyDQf9XIJJjd.4MSLBXVbyG75R3T1cayyh/";

  diskoCfg = lib.recursiveUpdate (import ../hosts/M90aPro/disko.nix { inherit lib; }) {
    disko.devices.disk.m90 = {
      device = "/dev/vdc";
      content.partitions = {
        ESP.size = "100M";
        swap.size = "32M";
        root.content = {
          passwordFile = "/tmp/key";
          extraFormatArgs = [ "--pbkdf" "pbkdf2" "--pbkdf-force-iterations" "1000" ];
        };
      };
    };
  };
  # The same builder as system.build.destroyFormatMount, with the mount point
  # layouts.nix gives (disko.rootMountPoint).
  diskoGen = pkgs.callPackage "${inputs.disko}" { checked = true; rootMountPoint = "/mnt/m90/new"; };
  diskoScript = diskoGen._cliDestroyFormatMount diskoCfg pkgs;

  # What `install` puts in the profile and runs inside nixos-enter.
  fakeSystem = pkgs.runCommand "nixos-system-m90-rehearsal" { } ''
    mkdir -p $out/bin $out/sw/bin
    ln -s ${pkgs.bash}/bin/bash $out/sw/bin/bash
    printf '#!${pkgs.runtimeShell}\nexit 0\n' > $out/activate
    printf '#!${pkgs.runtimeShell}\necho "$1 $NIXOS_INSTALL_BOOTLOADER" > /boot/stc-called\n' \
      > $out/bin/switch-to-configuration
    chmod +x $out/activate $out/bin/switch-to-configuration
  '';
in
pkgs.testers.runNixOSTest {
  name = "m90-btrfs-migration";

  nodes.machine = { pkgs, ... }: {
    virtualisation.emptyDiskImages = [ 3072 2048 ]; # vdb: old system, vdc: new disk
    virtualisation.memorySize = 2048;
    boot.supportedFilesystems = [ "btrfs" "vfat" "ntfs" ];
    # The tool carries its own; these set up and inspect the test disks.
    environment.systemPackages = with pkgs; [
      migrate gptfdisk attr cryptsetup e2fsprogs btrfs-progs dosfstools ntfs3g
    ];
    system.extraDependencies = [ fakeSystem diskoScript pkgs.hello ];
    nix.settings.experimental-features = [ "nix-command" ];
  };

  testScript = ''
    env = "M90_TARGET=/dev/vdc M90_KEY_FILE=/tmp/key M90_YES=1"
    state = "/home/thinky/.local/state/m90-migration"
    def migrate(phase):
        return machine.succeed(f"{env} m90-btrfs-migrate {phase} 2>&1")
    def migrate_fails(phase):
        return machine.fail(f"{env} m90-btrfs-migrate {phase} 2>&1")
    def no_mappers():
        machine.succeed("test -z \"$(ls /dev/mapper | grep -vx control)\"")

    machine.wait_for_unit("multi-user.target")
    machine.succeed(
        "printf secretsecret > /tmp/key",
        "sgdisk -n1:0:+64M -t1:EF00 -n2:0:0 -t2:8300 /dev/vdb",   # old M90aPro system
        "sgdisk -n1:0:+16M -t1:0C01 -n2:0:0 -t2:0700 /dev/vdc",   # emptied Windows disk
        "udevadm settle",
        "mkfs.vfat -i 6D0B8E30 /dev/vdb1",
        "cryptsetup luksFormat --batch-mode --type luks2 --uuid ${luksUuid}"
        " --pbkdf pbkdf2 --pbkdf-force-iterations 1000 /dev/vdb2 /tmp/key",
        "mkntfs -Q -f -L Data /dev/vdc2",
        "udevadm settle",
    )
    o = "/mnt/o"
    h = f"{o}/home/thinky/Projects"
    machine.succeed(
        "cryptsetup open /dev/vdb2 old --key-file /tmp/key",
        "mkfs.ext4 -q -F /dev/mapper/old",
        f"mkdir -p {o} && mount /dev/mapper/old {o}",
        f"nix copy --no-check-sigs --to {o} ${pkgs.hello}",
        # An old ext4 generation, which must not reach the new boot menu.
        f"ln -s ${pkgs.hello} {o}/nix/var/nix/profiles/system-1-link",
        f"ln -s system-1-link {o}/nix/var/nix/profiles/system",
        f"mkdir -p {o}/var/lib/nixos {o}/etc/NetworkManager/system-connections {o}/var/lib/libvirt {o}/root {o}/opt/tool",
        f"echo 'thinky:1000' > {o}/var/lib/nixos/uid-map",
        f"echo wifi > {o}/etc/NetworkManager/system-connections/home.nmconnection",
        f"chmod 600 {o}/etc/NetworkManager/system-connections/home.nmconnection",
        f"echo 0123456789abcdef0123456789abcdef > {o}/etc/machine-id",
        f"printf 'root:!:1::::::\\nthinky:${hash}:1::::::\\n' > {o}/etc/shadow",
        f"echo notes > {o}/root/notes.txt",
        f"echo vm > {o}/var/lib/libvirt/vm.xml",
        f"mkdir -p {h}/rusty/src {h}/rusty/target/debug {h}/site/target",
        f"echo 'Signature: 8a477f597d28d172789f06886806bc55' > {h}/rusty/target/CACHEDIR.TAG",
        f"echo junk > {h}/rusty/target/debug/junk",
        f"echo 'fn main(){{}}' > {h}/rusty/src/main.rs",
        f"echo page > {h}/site/target/index.html",  # not cargo's: kept
        f"echo keep > {h}/keep.txt",
        f"setfattr -n user.kept -v yes {h}/keep.txt",
        f"ln {h}/keep.txt {h}/keep-link.txt",
        f"chown -R 1000:100 {o}/home/thinky",
        f"umount {o} && cryptsetup close old",
    )
    # What Windows leaves on an emptied NTFS: a placeholder, not data.
    machine.succeed(
        "mkdir -p /mnt/w && mount -t ntfs3 /dev/vdc2 /mnt/w",
        "mkdir -p '/mnt/w/System Volume Information'",
        "touch '/mnt/w/System Volume Information/WPSettings.dat'",
        "umount /mnt/w",
    )
    # prepare's output, as `prepare` writes it on the PortableSSD.
    machine.succeed(
        f"mkdir -p {state}",
        f"ln -s ${fakeSystem} {state}/system",
        f"ln -s ${diskoScript} {state}/disko-format",
        f"echo /dev/vdc > {state}/disko-device",
        # No final newline on purpose: the last entry must still be copied.
        f"printf 'dir /var/lib/nixos\\ndir /etc/NetworkManager/system-connections\\n"
        f"dir /var/lib/absent\\nfile /etc/machine-id' > {state}/persist.txt",
    )
    old_disk = machine.succeed("sha256sum /dev/vdb").split()[0]

    with subtest("check identifies both disks and lists what is not carried over"):
        out = migrate("check")
        assert "Old system disk: /dev/vdb" in out and "New disk: /dev/vdc" in out, out
        assert "phase format : -" in out, out
        left = out.split("not carried over")[1]
        for want in ["/root/notes.txt", "/opt/tool", "/var/lib/libvirt"]:
            assert want in left, out
        for persisted in ["/var/lib/nixos", "machine-id", "home.nmconnection", "shadow"]:
            assert persisted not in left, out
        no_mappers()

    with subtest("refusals: files on the new disk, the old disk as target, a stale script, wrong order"):
        machine.succeed("mount -t ntfs3 /dev/vdc2 /mnt/w && touch /mnt/w/photo.jpg && umount /mnt/w")
        out = migrate_fails("format")
        assert "not empty" in out and "photo.jpg" in out, out
        machine.succeed("mount -t ntfs3 /dev/vdc2 /mnt/w && rm /mnt/w/photo.jpg && umount /mnt/w")
        out = machine.fail("M90_TARGET=/dev/vdb M90_KEY_FILE=/tmp/key M90_YES=1 m90-btrfs-migrate format 2>&1")
        assert "is the old system disk itself" in out, out
        machine.succeed(f"echo /dev/vdd > {state}/disko-device")
        assert "rerun 'prepare'" in migrate_fails("format")
        machine.succeed(f"echo /dev/vdc > {state}/disko-device")
        assert "run 'format' first" in migrate_fails("copy")
        assert "run 'copy' first" in migrate_fails("install")
        machine.succeed("test \"$(blkid -s LABEL -o value /dev/vdc2)\" = Data")  # untouched
        no_mappers()

    with subtest("format: disko lays out the new disk"):
        migrate("format")
        for label in ["disk-m90-ESP", "disk-m90-swap", "disk-m90-root"]:
            machine.succeed(f"test \"$(lsblk -no PKNAME $(readlink -f /dev/disk/by-partlabel/{label}))\" = vdc")
        machine.fail("findmnt /mnt/m90/new")
        no_mappers()
        assert "ran already" in migrate_fails("format")

    def check_new_disk():
        machine.succeed(
            "cryptsetup open --readonly /dev/disk/by-partlabel/disk-m90-root chk --key-file /tmp/key",
            "mkdir -p /mnt/chk && mount -o ro,subvol=/ /dev/mapper/chk /mnt/chk",
        )
        subvols = machine.succeed("btrfs subvolume list /mnt/chk")
        for s in ["@root", "@nix", "@persist", "@home"]:
            assert f"path {s}\n" in subvols + "\n", subvols
        machine.succeed("test \"$(blkid -s LABEL -o value /dev/mapper/chk)\" = nixos-m90")
        n = "/mnt/chk/@home/thinky/Projects"
        machine.succeed(f"test \"$(stat -c %u:%g {n}/keep.txt)\" = 1000:100")
        machine.succeed(f"test \"$(stat -c %h {n}/keep.txt)\" = 2")
        machine.succeed(f"getfattr -n user.kept {n}/keep.txt | grep -q yes")
        machine.succeed(f"test -e {n}/rusty/src/main.rs")
        machine.fail(f"test -e {n}/rusty/target")
        machine.succeed(f"test -e {n}/site/target/index.html")
        p = "/mnt/chk/@persist"
        machine.succeed(f"grep -q thinky:1000 {p}/var/lib/nixos/uid-map")
        machine.succeed(f"test \"$(stat -c %a {p}/etc/NetworkManager/system-connections/home.nmconnection)\" = 600")
        machine.succeed(f"grep -q 0123456789abcdef {p}/etc/machine-id")
        machine.fail(f"test -e {p}/var/lib/absent")
        machine.succeed(f"grep -qxF '${hash}' {p}/passwords/thinky")
        machine.succeed(f"grep -qx '!' {p}/passwords/root")
        machine.succeed(f"test \"$(stat -c %a {p}/passwords/thinky)\" = 600")
        s = "/mnt/chk/@nix"
        machine.succeed(f"test -e {s}/var/nix/db/db.sqlite")
        machine.succeed(f"test -e {s}/store/$(basename ${pkgs.hello})")       # the old store came along
        machine.succeed(f"test -e {s}/store/$(basename ${fakeSystem})")      # and the prepared system
        pr = f"{s}/var/nix/profiles"
        machine.succeed(f"test \"$(readlink {pr}/system)\" = system-2-link")
        machine.succeed(f"test \"$(readlink {pr}/system-2-link)\" = ${fakeSystem}")
        machine.fail(f"test -e {pr}/system-1-link")                         # old ext4 generation gone
        machine.succeed("umount /mnt/chk && cryptsetup close chk")
        machine.succeed("mkdir -p /mnt/esp && mount /dev/disk/by-partlabel/disk-m90-ESP /mnt/esp")
        machine.succeed("grep -qx 'boot 1' /mnt/esp/stc-called")
        machine.succeed("umount /mnt/esp")

    with subtest("copy, install"):
        migrate("copy")
        migrate("install")
        out = migrate("check")
        assert "phase install : done" in out, out
        check_new_disk()
        no_mappers()

    with subtest("the old disk was only ever read"):
        assert machine.succeed("sha256sum /dev/vdb").split()[0] == old_disk

    with subtest("umount after an interrupted phase leaves nothing behind"):
        machine.succeed("cryptsetup open /dev/disk/by-partlabel/disk-m90-root cryptpool --key-file /tmp/key")
        machine.succeed("mkdir -p /mnt/m90/new && mount -o subvol=@root /dev/mapper/cryptpool /mnt/m90/new")
        migrate("umount")
        machine.fail("findmnt /mnt/m90/new")
        no_mappers()
  '';
}
