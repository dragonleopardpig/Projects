# Portable NixOS SSD Installation Guide

Install a LUKS-encrypted, UEFI-bootable NixOS on an external SSD that boots on any x86_64 machine.

## Partition Layout

| Partition | Size | Format      | Purpose                          |
|-----------|------|-------------|----------------------------------|
| 1 (ESP)   | 10G  | FAT32       | `/boot` (EFI System Partition)   |
| 2 (root)  | 90G  | LUKS → ext4 | `/` (encrypted NixOS root)       |
| 3 (data)  | Rest | FAT32       | Portable data (not auto-mounted) |

## Prerequisites

- NixOS flake repo at `~/Projects/NixOS` with the `PortableSSD` host configured
- External SSD plugged in (identify with `lsblk`)
- The `PortableSSD` host files must be tracked by git (`git add`) for the flake to see them

## Step 1: Identify the SSD

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
```

Find your external SSD (e.g. `/dev/sdb`). **Make sure you identify the correct device — all data will be erased.**

## Step 2: Update disko.nix device path

Edit `hosts/PortableSSD/disko.nix` and set the correct device:

```nix
device = "/dev/sdX";  # Replace with your actual device
```

## Step 3: Unmount the SSD

```bash
sudo umount /dev/sdX1  # Unmount all existing partitions
sudo umount /dev/sdX2
# ... etc for all mounted partitions
```

## Step 4: Write the LUKS password file

```bash
printf '%s' 'YOUR_LUKS_PASSWORD' | sudo tee /tmp/luks-password > /dev/null
```

Disko reads the LUKS passphrase from `/tmp/luks-password` during setup.

## Step 5: Stage files for the flake

The flake only sees git-tracked files. Make sure new/modified files are staged:

```bash
cd ~/Projects
git add NixOS/hosts/PortableSSD/ NixOS/flake.nix
```

## Step 6: Partition, encrypt, and format with disko

```bash
sudo nix run github:nix-community/disko -- --mode disko ~/Projects/NixOS/hosts/PortableSSD/disko.nix
```

This will:
- Wipe the disk and create a GPT partition table
- Create the ESP (FAT32), LUKS-encrypted root (ext4), and data (FAT32) partitions
- Open the LUKS container
- Mount root to `/mnt` and boot to `/mnt/boot`

## Step 7: Get UUIDs and update hardware-configuration.nix

```bash
lsblk -o NAME,SIZE,FSTYPE,UUID,MOUNTPOINT /dev/sdX
sudo blkid /dev/sdX2   # LUKS partition UUID
```

Update `hosts/PortableSSD/hardware-configuration.nix` with the actual UUIDs:

```nix
# LUKS device — use the UUID of the crypto_LUKS partition (sdX2)
boot.initrd.luks.devices."cryptroot".device = "/dev/disk/by-uuid/<LUKS-UUID>";

# Root filesystem — use /dev/mapper/cryptroot (fixed name)
fileSystems."/" = {
  device = "/dev/mapper/cryptroot";
  fsType = "ext4";
};

# Boot/ESP — use the UUID of the vfat partition (sdX1)
fileSystems."/boot" = {
  device = "/dev/disk/by-uuid/<ESP-UUID>";
  fsType = "vfat";
  options = [ "fmask=0077" "dmask=0077" ];
};
```

Re-stage after editing:

```bash
git add NixOS/hosts/PortableSSD/hardware-configuration.nix
```

## Step 8: Install NixOS

```bash
sudo nixos-install --flake ~/Projects/NixOS#PortableSSD --root /mnt
```

This builds the entire system closure and installs GRUB to the EFI fallback path (`EFI/BOOT/BOOTX64.EFI`).

## Step 9: Set user passwords

```bash
sudo nixos-enter --root /mnt -c 'echo "thinky:YOUR_PASSWORD" | chpasswd'
sudo nixos-enter --root /mnt -c 'echo "root:YOUR_PASSWORD" | chpasswd'
```

## Step 10: Clean up and unmount

```bash
sudo rm /tmp/luks-password
sudo umount /mnt/boot
sudo umount /mnt
sudo cryptsetup close cryptroot
```

## Step 11: Boot

Plug the SSD into any x86_64 UEFI machine, enter the boot menu (usually F12/F2/Esc/Del), and select the external SSD. You'll be prompted for the LUKS passphrase, then GRUB loads NixOS.

## Rebuilding from the portable SSD

When booted into the portable NixOS and you want to apply config changes:

```bash
sudo nixos-rebuild switch --flake ~/Projects/NixOS#PortableSSD
```

## Key portability settings

These settings in `default.nix` make it boot on any machine:

- `boot.loader.grub.efiInstallAsRemovable = true` — installs GRUB to the UEFI fallback path so no firmware entries are needed
- `boot.loader.efi.canTouchEfiVariables = lib.mkForce false` — won't modify host machine's EFI firmware
- `boot.initrd.kernelModules = lib.mkForce []` — no NVIDIA in initrd (would fail on non-NVIDIA machines)
- `boot.plymouth.enable = lib.mkForce false` — disabled for GPU driver compatibility
- Broad `initrd.availableKernelModules` — covers USB, AHCI, NVMe, SD card controllers
- Both `kvm-intel` and `kvm-amd` included
- All filesystems referenced by UUID, not device path

## Troubleshooting

**Kernel caches old partition table after re-partitioning:**
If `partprobe` reports "device busy" and old partitions persist:
```bash
# Remove and rescan the device via sysfs
echo 1 | sudo tee /sys/block/sdX/device/delete
sleep 3
echo "- - -" | sudo tee /sys/class/scsi_host/host*/scan
sleep 5
lsblk  # Device may come back as a different letter (e.g. sdc)
```
Update `disko.nix` with the new device path before proceeding.

**Data partition auto-mounts after disko:**
```bash
sudo umount /run/media/thinky/<UUID>
```
