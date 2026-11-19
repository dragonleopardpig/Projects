# CRUCIAL-SSD: ext4 → impermanent btrfs

**Done 2026-11-20**: CRUCIAL-SSD runs the btrfs layout; `layouts.nix` defaults
to `"btrfs"` and the temporary `CRUCIAL-SSD-btrfs` flake output is gone (so
`prepare` no longer applies).  Left: B6 after a week of good boots.

One-time move of this host to the layout PortableSSD already uses: `/` wiped on
every boot, regenerable dev artifacts cleaned, everything else kept.  The tool
is `crucial-btrfs-migrate` (`scripts/crucial-btrfs-migrate.sh`, installed on
PortableSSD).  The VM rehearsal runs every phase on a disk of the same shape:
`nix build .#checks.x86_64-linux.crucial-migration -L`.

## What changes

| | Today (ext4) | After (btrfs, same LUKS container) |
|---|---|---|
| `/` | ext4, kept | `@root`, **new every boot** (old roots kept 14 days in `old_roots/`) |
| `/nix`, `/home` | kept | `@nix`, `@home`: kept |
| system state | in place | `@persist`, bind-mounted (list in `modules/impermanence.nix`) |
| `/tmp` | kept across reboots (10-day age rule) | `@tmp`: **empty every boot**, same 10-day rule while running |
| swap | `/var/lib/swapfile` 16G | `@swap/swapfile` 16G |
| Rust intermediates | `./target/` (strata 38G, spacedrive 10G) | `/var/cache/dev` (`@dev-scratch`, empty every boot); binaries stay in `./target` |
| `.devenv`, `.venv`, `node_modules`, `.direnv` | kept | **kept** (`cleanDevEnvironments = false`) |
| `__pycache__`, `.pytest_cache`, docs builds, `result` links, tool caches | kept | removed at boot |
| Trash | kept | kept; items trashed over 30 days ago removed daily |
| passwords | `/etc/shadow` | same hashes, from `/persist/passwords` (copied, no retyping) |

Partitions are unchanged: `sda1` ESP, `sda2` LUKS (same UUID, same passphrase),
`sda3` CRUCIALDATA, `sda4` WinApps (never touched).

## B0: on CRUCIAL-SSD, before shutting down

1. Stop gates; tell the Kraken / trident sessions the machine goes down
   (about 2–3 hours).  After the migration a reboot empties `/tmp`, so
   agent scratchpads do not survive it.
2. Push every repo; `sync-projects` to the second SSD; copy `~/.ssh`,
   `~/.gnupg`, `~/Scramble Private`, `~/.claude` there too.
3. Make sure `sda3` (CRUCIALDATA) is empty: it becomes the staging area.
4. Build the new system and list what it persists (the tool is only
   installed on PortableSSD, so run the script directly, as thinky):
   ```bash
   bash ~/Projects/NixOS/scripts/crucial-btrfs-migrate.sh prepare
   ```
   It builds `nixosConfigurations.CRUCIAL-SSD-btrfs` into
   `~/.local/state/crucial-migration/system` (a GC root) and writes
   `persist.txt` next to it.
5. Put the tool on PortableSSD (plug it in; nothing on this host is activated):
   ```bash
   ~/Projects/NixOS/rebuild.sh boot PortableSSD
   ```
6. Shut down.

## B1–B4: booted from PortableSSD, Crucial disk attached

Run each phase, read its output, then the next.  `check` can be run any time;
`--dry-run PHASE` prints what a phase would do.

```bash
sudo crucial-btrfs-migrate check     # disk, partitions, phases done
sudo crucial-btrfs-migrate stage     # sda3 -> ext4 CRUCIAL-STAGE; exact image of today's root  [rollback point]
sudo crucial-btrfs-migrate format    # btrfs + @root @nix @persist @home @swap inside the LUKS  [ERASES ROOT]
sudo crucial-btrfs-migrate copy      # /nix, /home, persisted state, password hashes
sudo crucial-btrfs-migrate install   # system profile + GRUB on Crucial's ESP
```

Each phase asks for the LUKS passphrase and, before destructive steps, for a
typed word (STAGE, FORMAT).  It refuses to run from the Crucial system itself,
or if CRUCIALDATA is not empty.  After an interrupted phase:
`sudo crucial-btrfs-migrate umount`, then rerun it.

## B5: first boot of the migrated CRUCIAL-SSD

Unplug PortableSSD and boot.  The first boot removes the old build artifacts
(tens of GB of small files), so the login prompt may take a few minutes.

```bash
findmnt -t btrfs                             # / @root, /nix, /persist, /home, /swap, /tmp, /var/cache/dev
journalctl -b -u impermanence-clean-dev      # what the sweep removed
systemctl --failed
swapon --show                                # /swap/swapfile
podman ps -a; ls /mnt/winapps                # WinApps
cd ~/Projects/trident-optics && direnv exec . true   # devenv kept, loads at once
df -h /
```

Then a canary reboot: `sudo touch /canary; touch ~/canary; reboot`.  After it
`/canary` is gone, `~/canary` is still there.

When all is well, make the btrfs layout the default and push:

```nix
# hosts/Crucial-SSD/layouts.nix
default = "btrfs";
```
and remove the `CRUCIAL-SSD-btrfs` output from `flake.nix`.  Rebuild as usual
(`sudo nixos-rebuild switch --flake .#Crucial-SSD --impure`).  Do this
commit right after the checks: until then `.#Crucial-SSD` still means the
ext4 layout, and every rebuild of it (yours or an agent's) is refused by the
impermanence pre-switch check; `.#CRUCIAL-SSD-btrfs` works meanwhile.

## B6: after about a week of good boots

```bash
sudo crucial-btrfs-migrate release-stage   # deletes the image; sda3 is an empty FAT32 CRUCIALDATA again
```

## Rollback (any time before B6)

From PortableSSD:

```bash
sudo crucial-btrfs-migrate rollback        # writes the ext4 image back
```

Then boot CRUCIAL-SSD and pick the newest generation that is **older than
2026-11-20** in the GRUB menu (the ext4 system).  Set
`default = "ext4";` in `hosts/Crucial-SSD/layouts.nix`, commit, and run
`sudo nixos-rebuild boot --flake ~/Projects/NixOS#CRUCIAL-SSD --impure`
to make the ext4 system the default again.

## Recovering a file from a wiped root

```bash
sudo mount -o subvol=/ /dev/mapper/cryptroot /mnt && ls /mnt/old_roots
```
