# VM check of hosts/M90aPro/backup.nix, the daily restic backup to the Seagate,
# and of `backup-pool`, the helper behind the bar's Backup icon:
#
#   nix build .#checks.x86_64-linux.m90-backup -L
#
# With the disk unplugged the run is skipped, not failed, and the icon says so.
# With the partition present (same UUID as the real Linux-Data):
#   - the scheduler starts the backup when it is due, once a day, not while paused;
#   - /home and /persist are backed up; caches, Trash, cargo target/ and a mount
#     inside the home folder (an rclone cloud drive) are not; a file restores;
#     the disk never holds the plaintext (the Seagate is not encrypted);
#   - the user (no password, polkit) runs and stops a backup, and only that unit;
#     the icon shows the percentage while it runs and "stopped" after Stop;
#   - the user's settings apply at the next run: extra folders and excludes,
#     how many snapshots to keep;
#   - Browse shows every snapshot read-only, with the files' own permissions.
{ pkgs, lib }:
let
  uuid = "63f1d802-9a75-48b0-9dbe-89a0352456c9";
  common = { ... }: {
    imports = [ ../hosts/M90aPro/backup.nix ];
    users.users.thinky.isNormalUser = true;
    users.users.other.isNormalUser = true;
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
    import json

    start_all()
    machine.wait_for_unit("multi-user.target")
    unplugged.wait_for_unit("multi-user.target")

    def status(node=machine):
        return json.loads(node.succeed("su thinky -c 'backup-pool status'"))

    def as_thinky(cmd, node=machine):
        return node.succeed(f"su thinky -c '{cmd}'")

    def settings(**values):
        machine.succeed("su thinky -c 'mkdir -p ~/.config/backup-status'")
        machine.succeed(f"su thinky -c 'cat > ~/.config/backup-status/settings.json' <<'EOF'\n{json.dumps(values)}\nEOF")

    def summary():
        return json.loads(as_thinky("cat /persist/backup/pool-status.json"))

    def wait_idle():
        # not is-active: a running oneshot is "activating"
        machine.wait_until_succeeds(
            "systemctl show -p ActiveState --value restic-backups-pool.service | grep -qxE 'inactive|failed'", timeout=300)

    def last_attempt():
        return machine.succeed("${pkgs.jq}/bin/jq -r '.last_attempt // \"none\"' /persist/backup/pool-status.json 2>/dev/null || echo none").strip()

    def wait_for_run(before):
        # the summary is written as the run ends (ExecStopPost)
        machine.wait_until_succeeds(f"test \"$(${pkgs.jq}/bin/jq -r '.last_attempt // \"none\"' /persist/backup/pool-status.json 2>/dev/null || echo none)\" != '{before}'",
                                    timeout=300)
        wait_idle()

    def user_run():
        before = last_attempt()
        as_thinky("backup-pool run >/dev/null")
        wait_for_run(before)

    def save(form, node=machine, ok=True):
        node.succeed(f"cat > /tmp/form.json <<'EOF'\n{json.dumps(form)}\nEOF\nchmod 644 /tmp/form.json")
        run = node.succeed if ok else node.fail
        return run("su thinky -c 'backup-pool save-settings --json \"$(cat /tmp/form.json)\"'")

    def make_due():
        machine.succeed("${pkgs.jq}/bin/jq '.last_success = 0' /persist/backup/pool-status.json > /tmp/s"
                        " && cat /tmp/s > /persist/backup/pool-status.json")

    def snapshots():
        return int(machine.succeed("restic-pool snapshots --json | ${pkgs.jq}/bin/jq length").strip())

    with subtest("disk unplugged: skipped, not failed; the icon says unplugged"):
        unplugged.succeed("${secret}")
        unplugged.succeed("systemctl list-timers --all | grep -q backup-pool-scheduler.timer")
        # the test starts the scheduler itself
        unplugged.succeed("systemctl stop backup-pool-scheduler.timer")
        machine.succeed("systemctl stop backup-pool-scheduler.timer")
        unplugged.fail("systemctl list-timers --all | grep -q restic-backups-pool.timer")
        unplugged.succeed("systemctl start backup-pool-scheduler.service")
        assert "backup unplugged" in unplugged.succeed("journalctl -u backup-pool-scheduler -o cat")
        unplugged.succeed("systemctl start restic-backups-pool.service")
        unplugged.succeed("test \"$(systemctl show -p ConditionResult --value restic-backups-pool.service)\" = no")
        unplugged.fail("systemctl is-failed -q restic-backups-pool.service")
        s = status(unplugged)
        assert s["state"] == "unplugged" and not s["can_run"], s
        assert s["next_text"] == "as soon as the disk is plugged in", s
        unplugged.fail("su thinky -c 'backup-pool run'")

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
        assert status()["state"] == "overdue", status()

    with subtest("the scheduler starts the first backup, and only once a day"):
        machine.succeed("systemctl start backup-pool-scheduler.service")
        wait_for_run("none")
        machine.fail("systemctl is-failed -q restic-backups-pool.service")
        s = summary()
        assert s["last_result"] == "success" and s["snapshots"] == 1, s
        assert s["last_added"] and s["latest"]["id"], s
        machine.succeed("systemctl start backup-pool-scheduler.service")
        assert "backup done" in machine.succeed("journalctl -u backup-pool-scheduler -o cat")
        assert snapshots() == 1
        st = status()
        assert st["state"] == "ok" and st["snapshots"] == 1 and st["can_browse"], st
        assert st["summary"] == "Last backup just now", st

    with subtest("backup contents"):
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

    with subtest("paused: the scheduler leaves a due backup alone"):
        make_due()
        save({"paused": True})
        assert status()["state"] == "paused", status()
        machine.succeed("systemctl start backup-pool-scheduler.service")
        assert "backup paused" in machine.succeed("journalctl -u backup-pool-scheduler -o cat")
        machine.succeed("systemctl show -p ActiveState --value restic-backups-pool.service | grep -qx inactive")

    # restic keeps the newest snapshot of each day, and while fewer days than
    # --keep-daily exist also the oldest one, so early history is not lost.
    with subtest("the user runs it (polkit, no password): same-day runs keep the oldest and the newest"):
        for version in ["second-version", "third-version"]:
            machine.succeed(f"su thinky -c 'echo {version} > ~/doc.txt'")
            user_run()
            assert snapshots() == 2, snapshots()
        machine.succeed("restic-pool restore latest --target /tmp/restore2 --include /home/thinky/doc.txt")
        machine.succeed("grep -qx third-version /tmp/restore2/home/thinky/doc.txt")
        # polkit lets the user start exactly the two backup units
        machine.fail("su thinky -c 'systemctl --no-ask-password start backup-pool-scheduler.service'")
        machine.fail("su other -c 'systemctl --no-ask-password start restic-backups-pool.service'")

    with subtest("the user's extra folder, extra exclude and keep counts apply at the next run"):
        machine.succeed("mkdir -p /srv/extra && echo extra > /srv/extra/file.txt")
        as_thinky("dd if=/dev/urandom of=~/disk.iso bs=1k count=4 status=none")
        form = json.dumps({"paused": "false", "extra_paths": "/srv/extra", "extra_excludes": "*.iso",
                           "keep_daily": "1", "keep_weekly": "0", "keep_monthly": "0"})
        save(json.loads(form))
        bad = save({"time": "noon"}, ok=False)
        assert "not HH:MM" in json.loads(bad)["action_error"], bad
        user_run()
        listing = machine.succeed("restic-pool ls latest")
        assert "/srv/extra/file.txt" in listing, listing
        assert "disk.iso" not in listing, listing
        assert snapshots() == 1, snapshots()
        st = status()
        assert st["settings"]["keep"] == {"daily": 1, "weekly": 0, "monthly": 0}, st
        assert st["settings"]["extra_paths"] == ["/srv/extra"], st

    with subtest("running: the icon shows the percentage; Stop ends it, shown as stopped"):
        # 600 GB of zeros (sparse): restic reads them for minutes (about 3 GB/s here)
        # but stores almost nothing.
        machine.succeed("mkdir -p /srv/slow && truncate -s 600G /srv/slow/zeros")
        settings(extra_paths=["/srv/slow"], keep={"daily": 1, "weekly": 0, "monthly": 0})
        as_thinky("backup-pool run >/dev/null")
        machine.wait_until_succeeds(
            "su thinky -c 'backup-pool status' | ${pkgs.jq}/bin/jq -e '.state == \"running\" and .percent != null'",
            timeout=120)
        st = status()
        assert st["can_stop"] and not st["can_run"] and st["phase"] == "backing up", st
        assert "GiB" in st["progress_text"], st
        before = last_attempt()
        as_thinky("backup-pool stop >/dev/null")
        wait_for_run(before)
        assert summary()["last_result"] == "stopped", summary()
        st = status()
        assert st["state"] == "stopped", st
        machine.fail("systemctl is-failed -q restic-backups-pool.service")
        # the next run is not blocked by the killed run's lock
        settings(keep={"daily": 1, "weekly": 0, "monthly": 0})
        user_run()
        assert summary()["last_result"] == "success", summary()
        assert status()["state"] == "ok", status()

    with subtest("Browse: every snapshot, read-only, with the files' own permissions"):
        as_thinky("backup-pool browse-start >/dev/null")
        assert status()["state"] == "browsing", status()
        latest = "/run/restic-browse-pool/mnt/snapshots/latest"
        assert as_thinky(f"cat {latest}/home/thinky/doc.txt").strip() == "third-version"
        machine.fail(f"su other -c 'cat {latest}/home/thinky/doc.txt'")
        machine.fail(f"su thinky -c 'touch {latest}/home/thinky/new.txt'")
        # a backup still runs while browsing
        make_due()
        before = last_attempt()
        machine.succeed("systemctl start backup-pool-scheduler.service")
        wait_for_run(before)
        s = summary()
        assert s["last_result"] == "success", s
        # pruning would wait on Browse's lock: skipped at once, done next run
        assert s["last_prune_ok"] is False and s["last_prune_note"] == "Browse was open", s
        assert status()["prune_failed"], status()
        as_thinky("backup-pool browse-stop >/dev/null")
        machine.fail(f"test -e {latest}")
        assert status()["state"] == "ok", status()
        user_run()
        assert summary()["last_prune_ok"] is True, summary()
        assert not status()["prune_failed"], status()
  '';
}
