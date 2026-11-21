# M90aPro: ext4 → impermanent btrfs pool on both SSDs

**B0–B4 done 2026-11-21**: M90aPro runs the btrfs layout on `S7XLNE0Y733872`;
`layouts.nix` defaults to `"btrfs"` and the temporary `M90aPro-btrfs` flake
output is gone (so `prepare` no longer applies).  Left: Part C after about a
week of good boots.

The M90aPro moves to the layout CRUCIAL-SSD and the PortableSSD use: `/` wiped
on every boot, regenerable dev artifacts cleaned, dependency environments and
everything else kept.  Unlike CRUCIAL-SSD it moves to its **other SSD**, so the
old system stays untouched as the fallback.  After a week of good boots the old
SSD **joins the same btrfs**, giving one pool across both (no mirror).

The tool is `m90-btrfs-migrate` (`scripts/m90-btrfs-migrate.sh`), installed on
the PortableSSD and on the btrfs M90aPro.  VM rehearsals:
`nix build .#checks.x86_64-linux.m90-migration -L` (prepare → install) and
`.#checks.x86_64-linux.impermanence-m90 -L` (the layout, then Part C).

## Disks

The three Samsung NVMe drives change `/dev/nvmeXn1` numbers between boots, so
everything names them by serial (`/dev/disk/by-id/nvme-SAMSUNG_MZVL8256HFJD-00BLL_<serial>`):

| Serial | Before | After the migration | After Part C |
|---|---|---|---|
| `S7XLNE0Y733872` | emptied Windows data disk | ESP 1G, swap 16G (random key each boot), LUKS `cryptpool` → btrfs `@root @nix @persist @home` | pool member 1 |
| `S7XLNE0Y733865` | NixOS ext4 (LUKS `e4268bbb…`, ESP `6D0B-8E30`) | untouched: the fallback, firmware entry **NixOS-boot** | one LUKS partition `m90-pool2`, pool member 2 |
| `S7XLNE0Y733874` | Windows | untouched | untouched |

The pool keeps **data `single`** (about 440 GB, no mirror) and **metadata
`raid1`**.  If one SSD dies the pool mounts with `-o degraded,ro`, so the files on
the other one can be rescued; for everything else rely on the backups
(`sync-projects` to the X299-SSD).

The new system boots from its own firmware entry **NixOS-pool**.  The old disk
keeps **NixOS-boot**: rollback means picking it in the boot menu (F12).

## B0: preparation (on the PortableSSD, booted on the M90aPro)

1. The tool must be on the PortableSSD (`rebuild.sh boot PortableSSD` from any host).
2. As thinky:
   ```bash
   m90-btrfs-migrate prepare    # builds M90aPro-btrfs + disko's format script, lists persisted paths
   ```

## B1–B3: format, copy, install (on the PortableSSD)

```bash
sudo m90-btrfs-migrate check     # both disks; old root's size; what would NOT be carried over
sudo m90-btrfs-migrate format    # [ERASES S7XLNE0Y733872] disko: ESP, swap, LUKS -> btrfs
sudo m90-btrfs-migrate copy      # /nix, /home, persisted state, password hashes; the new system
sudo m90-btrfs-migrate install   # profile + GRUB, firmware entry NixOS-pool (first in boot order)
```

- `format` asks for the new disk's passphrase twice (use the old disk's, so the
  pool later opens with one prompt). It keeps it in `/dev/shm/m90-luks-key` (RAM) for the
  later phases.  Delete the file afterwards; a reboot also clears it.
- `format` refuses if the target holds anything besides Windows' placeholders, or if
  the prepared disko script names any other disk.
- `copy` opens the old disk read-only.  It skips cargo `target/` directories (they are
  rebuilt on use).
- `install` drops the old ext4 generations from the new boot menu.
- After an interrupted phase: `sudo m90-btrfs-migrate umount`, then rerun it.

## B4: first boot from the new disk

Unplug the PortableSSD and boot (the firmware starts NixOS-pool).

```bash
findmnt -t btrfs                          # / @root, /nix, /persist, /home, /tmp, /var/cache/dev
swapon --show                             # the swap partition (TYPE partition)
journalctl -b -u impermanence-clean-dev   # what the boot sweep removed
systemctl --failed
nvidia-smi; # F7 display modes, external screen
cd ~/Projects/trident-optics && direnv exec . true   # environment kept, loads at once
df -h /
```

Canary reboot: `sudo touch /canary; touch ~/canary; reboot`.  Afterwards `/canary`
is gone and `~/canary` is still there.

Then make btrfs the default and push:

```nix
# hosts/M90aPro/layouts.nix
default = "btrfs";
```

and remove the `M90aPro-btrfs` output from `flake.nix`.  Until then `.#M90aPro`
still means the ext4 layout, and the impermanence pre-switch check refuses it on
the new disk.  Use `.#M90aPro-btrfs` meanwhile.

## Part C: the old SSD joins the pool (after about a week of good boots)

From the btrfs M90aPro:

```bash
sudo m90-btrfs-migrate extend-prepare   # [ERASES S7XLNE0Y733865] one LUKS partition m90-pool2, same passphrase
```

Then set `custom.m90Pool.secondDisk = true;` (`hosts/M90aPro/layouts.nix`, btrfs
branch), commit, `sudo nixos-rebuild boot --flake ~/Projects/NixOS#M90aPro`, and
**reboot**.  initrd now unlocks both disks (one prompt).  Then:

```bash
sudo m90-btrfs-migrate extend           # btrfs device add + metadata -> raid1
btrfs filesystem usage -T /
```

The order matters, and `extend` enforces it: the second disk joins the
filesystem only once the running system *and* the default boot entry unlock it,
so no boot ever meets a pool member it cannot open.  After Part C the old system
(NixOS-boot) is gone; its firmware entry can be removed with `efibootmgr`.

## Recovering a file from a wiped root

```bash
sudo mount -o subvol=/ /dev/mapper/cryptpool /mnt && ls /mnt/old_roots
```
