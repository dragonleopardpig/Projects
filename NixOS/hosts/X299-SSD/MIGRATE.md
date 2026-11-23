# X299-SSD: ext4 → impermanent btrfs, CRUCIAL-style partitions

The last host on ext4.  The disk (Buffalo SSD, 931.5 GB) is migrated **from the
M90aPro**, plugged in by USB; the rollback point goes to the Seagate's
`Linux-Data` (`/mnt/backup`).  Tool: `x299-btrfs-migrate`
(`scripts/x299-btrfs-migrate.sh`, installed on M90aPro), rehearsed end to end by
`nix build .#checks.x86_64-linux.x299-migration -L`; the new layout itself by
`.#checks.x86_64-linux.impermanence-x299`.

## What changes

| Partition | Before | After |
|---|---|---|
| p1 | BIOS-BOOT 8 MiB (unused: GRUB is EFI only) | **EFI 10 GiB**, FAT32, same volume id `0C04-2087` |
| p2 | EFI 98 GiB (92 MB used) | **LUKS2**, same UUID `d9622547…`, same passphrase → btrfs `@root @nix @persist @home @swap` |
| p3 | LUKS2 → ext4 root (333 GiB) | DATA (was p4), **renumbered only** |
| p4 | DATA (FAT, 400 GiB) | Virtual Windows / WinApps (was p5), **renumbered only** |
| p5 | Virtual Windows (ext4, 100 GiB) | — |

The same partition style and numbers as CRUCIAL-SSD (p1 ESP, p2 LUKS root,
p3 data, p4 WinApps).  DATA and Virtual Windows keep their sectors and contents;
only their table entries move.  The root grows from 333 to ~421 GiB (the ESP's
unused 88 GiB).  Everything the configuration refers to is found by UUID, so
nothing else changes.

## What is copied

| | Copied | Left out |
|---|---|---|
| `/nix` | only the new system's closure, plus the closures of the user Nix profile (Chrome, Edge, Teams, gthumb, nomacs, Asana), with GC roots | the old 79 GB store: its ext4 generations cannot boot the new layout |
| `/home` | everything else | what the boot sweep removes anyway (`modules/impermanence-clean-dev.py`: `target/`, `__pycache__`, `.devenv`, `.direnv`, `.venv`, `node_modules`, tool caches, about 45 GiB), and `~/.cache` (23 GB, 18 GB of it uv's) |
| system state | the paths `environment.persistence` lists (`/var/log`, NetworkManager, bluetooth, machine-id, …) | everything else in `/`, `/tmp`, `/var/lib/swapfile` |
| passwords | the hashes from `/etc/shadow`, into `/persist/passwords` | — |

Dependency environments are not kept across boots on X299 either
(`cleanDevEnvironments` stays on): `direnv`/devenv rebuild them on first use.

## Security

The stage disk is not encrypted.  Nothing decrypted is written to it: `stage`
images the LUKS partition **raw** (still encrypted, checksummed), and `copy`
reads that image through dm-crypt.  The passphrase lives only in a RAM file.
`Scramble Private` therefore never lands in plaintext on Linux-Data.

## Steps (on M90aPro)

1. Install the tool: `~/Projects/NixOS/rebuild.sh switch`.  Daily backups to
   Linux-Data run at 12:30.  If the migration would overlap that, pause them in
   the Backup panel.
2. Stop automounting (udiskie would grab every partition that appears while the
   table is rewritten), and type the passphrase into RAM, in a terminal:

   ```bash
   systemctl --user stop udiskie
   read -rs p && printf %s "$p" | sudo install -m 600 /dev/stdin /dev/shm/x299.key && unset p
   ```

3. Run the phases in order.  Each one checks what came before it, and each
   destructive one asks for a typed word first:

   ```bash
   sudo x299-btrfs-migrate prepare   # build X299-SSD (btrfs), list what it persists
   sudo x299-btrfs-migrate check     # disk, layout (old), phases
   sudo x299-btrfs-migrate stage     # unmount + lock the root; GPT, first sectors,
                                     # ESP files, raw root -> /mnt/backup/x299-migration
                                     # (333 GB, written then read back: about an hour)
   sudo x299-btrfs-migrate format    # new table, ESP, LUKS, btrfs   [ERASES the root]
   sudo x299-btrfs-migrate copy      # system, profiles, /home, state, passwords
   sudo x299-btrfs-migrate install   # system profile + GRUB (removable path, no NVRAM)
   ```

4. Clean up: `sudo rm /dev/shm/x299.key; systemctl --user start udiskie`.

## Step 5: first boot of X299-SSD

Boot it from any machine's boot menu (it is the EFI removable entry).  The
GRUB menu may also list systems from the M90aPro's disks, because os-prober ran
during `install`.  Those entries go away at the first rebuild on X299 itself.

```bash
findmnt -t btrfs            # / = @root, /nix, /persist, /home, /swap
systemctl --failed          # nothing
swapon --show               # /swap/swapfile
sudo touch /canary; touch ~/canary; reboot
ls /canary ~/canary         # /canary gone, ~/canary kept
```

Then, in `~/Projects/NixOS`:
1. Set the `custom.x299Layout` default in `layouts.nix` to `"btrfs"`. (done 2026-11-23)
2. Remove the temporary `X299-SSD-btrfs` output from `flake.nix`. (done 2026-11-23)
3. Run `rebuild.sh boot` on X299, reboot, and push.  Not `switch`: the first
   boot comes up in SDDM's Hyprland session, because `prepare` built the host
   before it had `desktop.noctaliaSuite.greeter.enable` (added 2026-11-23), and
   the switch from SDDM to the Noctalia Greeter would log you out mid-rebuild.
   After the reboot the greeter starts Noctalia Suite on Umbriel.  (done
   2026-11-23: generation 2, `rollback-root` wiped `@root` at boot, `/home` kept)

Once X299 has booted, plug its disk into M90aPro again and run
`sudo x299-btrfs-migrate release-stage`.  It refuses until the new root holds a
journal written after `install`, then deletes the stage directory.  After that,
remove the tool from `hosts/M90aPro/default.nix`.

## Rollback

`sudo x299-btrfs-migrate rollback` can run at any point before `release-stage`,
including after a `format` that was cut short, when the LUKS header is gone and
the disk is found by the id saved at `stage`.  It puts the old partition table,
the MBR boot code, BIOS boot, the ESP's files and the raw encrypted root back,
then checks the ext4 inside.  X299 then boots its old generation (481).

## Afterwards

`sync-projects` (`noctalia/suite/rsync-status.py`) keeps the configured target
`/run/media/thinky/nixos/home/thinky`.  On the btrfs disk, mounted by udisks at
its top level, it finds `…/nixos/@home/thinky` by itself.
