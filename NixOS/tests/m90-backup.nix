# VM check of hosts/M90aPro/backup.nix, the daily restic backup to the Seagate:
#
#   nix build .#checks.x86_64-linux.m90-backup -L
#
# With the disk unplugged the run is skipped, not failed.  With the partition
# present (same UUID as the real Linux-Data): /home and /persist are backed up,
# caches, Trash, cargo target/ and a mount inside the home folder (an rclone
# cloud drive) are not; a file restores; the disk never holds the plaintext
# (restic encrypts: the Seagate is not encrypted); and further runs the same day
# are pruned to the oldest and the newest snapshot, the newest holding the new content.
{ pkgs, lib }:
let
  uuid = "63f1d802-9a75-48b0-9dbe-89a0352456c9";
  common = { ... }: {
    imports = [ ../hosts/M90aPro/backup.nix ];
    users.users.thinky.isNormalUser = true;
    virtualisation.memorySize = 1024;
  };
  secret = "install -d -m 700 /persist/secrets && printf backup-pass > /persist/secrets/restic-m90.pass"
    + " && chmod 600 /persist/secrets/restic-m90.pass";
in
pkgs.testers.runNixOSTest {
  name = "m90-backup";

  nodes.machine = { ... }: {
    imports = [ common ];
    virtualisation.emptyDiskImages = [ 1024 ]; # /dev/vdb: the Seagate's Linux-Data
  };
  nodes.unplugged = { ... }: { imports = [ common ]; };

  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")
    unplugged.wait_for_unit("multi-user.target")

    with subtest("disk unplugged: the run is skipped, not failed"):
        unplugged.succeed("${secret}")
        unplugged.succeed("systemctl start restic-backups-pool.service")
        unplugged.succeed("test \"$(systemctl show -p ConditionResult --value restic-backups-pool.service)\" = no")
        unplugged.fail("systemctl is-failed -q restic-backups-pool.service")
        unplugged.succeed("systemctl list-timers --all | grep -q restic-backups-pool.timer")

    with subtest("data, and what must stay out of the backup"):
        machine.succeed(
            "mkfs.ext4 -q -U ${uuid} -L Linux-Data /dev/vdb",
            "udevadm settle",
            "test -e /dev/disk/by-uuid/${uuid}",
            "${secret}",
            "mkdir -p /persist/var/lib/nixos && echo state-canary > /persist/var/lib/nixos/state.txt",
            "su thinky -c 'mkdir -p ~/Projects/rusty/target ~/.cache ~/.local/share/Trash/files ~/.local/share/containers'",
            "su thinky -c 'echo plaintext-canary-7f3a > ~/doc.txt && echo keep > ~/Projects/rusty/main.rs'",
            "su thinky -c 'echo junk > ~/.cache/junk && echo junk > ~/.local/share/Trash/files/old.txt'",
            "su thinky -c 'echo junk > ~/.local/share/containers/layer && echo junk > ~/Projects/rusty/target/junk'",
            "su thinky -c 'printf \"Signature: 8a477f597d28d172789f06886806bc55\" > ~/Projects/rusty/target/CACHEDIR.TAG'",
            "su thinky -c 'mkdir -p \"$HOME/Google Drive\"'",
            "mount -t tmpfs cloud '/home/thinky/Google Drive' && echo cloud > '/home/thinky/Google Drive/cloud.txt'",
        )

    with subtest("backup"):
        machine.succeed("systemctl start restic-backups-pool.service")
        machine.fail("systemctl is-failed -q restic-backups-pool.service")
        listing = machine.succeed("restic-pool ls latest")
        for kept in ["/home/thinky/doc.txt", "/home/thinky/Projects/rusty/main.rs", "/persist/var/lib/nixos/state.txt"]:
            assert kept in listing, listing
        for left_out in [".cache/junk", "Trash/files/old.txt", "containers/layer", "rusty/target/junk", "cloud.txt"]:
            assert left_out not in listing, left_out + " was backed up:\n" + listing

    with subtest("the unencrypted disk holds no plaintext; a file restores"):
        machine.succeed("test -d /mnt/backup/restic/m90apro/data")
        machine.fail("grep -rq plaintext-canary-7f3a /mnt/backup")
        machine.succeed("restic-pool restore latest --target /tmp/restore --include /home/thinky/doc.txt")
        machine.succeed("grep -qx plaintext-canary-7f3a /tmp/restore/home/thinky/doc.txt")

    # restic keeps the newest snapshot of each day, and while fewer days than
    # --keep-daily exist also the oldest one, so early history is not lost.
    def snapshots():
        return int(machine.succeed("restic-pool snapshots --json | ${pkgs.jq}/bin/jq length").strip())

    with subtest("more runs the same day: the oldest and the newest stay, the ones between are pruned"):
        for version in ["second-version", "third-version"]:
            machine.succeed(f"su thinky -c 'echo {version} > ~/doc.txt'")
            machine.succeed("systemctl start restic-backups-pool.service")
            assert snapshots() == 2, snapshots()
        machine.succeed("restic-pool restore latest --target /tmp/restore2 --include /home/thinky/doc.txt")
        machine.succeed("grep -qx third-version /tmp/restore2/home/thinky/doc.txt")
  '';
}
