# NixOS Installation on nvme1n1 (M90aPro) using Disko

## Partition Layout

```
nvme1n1
├── p1  1G    ESP   /boot  (FAT32)
└── p2  rest  LUKS  (single passphrase)
    └── LVM "pool"
        ├── root  100G  ext4  /
        └── home  rest  ext4  /home
```

## Prerequisites

- NixOS installer USB (boot from it)
- Your flake repo accessible (USB stick or git clone)
- WiFi SSID and password

---

## Step 1: Connect to Internet

The NixOS installer uses `wpa_supplicant` by default.

### Option A: Ethernet (if available)

Just plug in. Verify with:

```bash
ping -c 3 nixos.org
```

### Option B: WiFi

```bash
sudo systemctl start wpa_supplicant
wpa_cli
```

Inside `wpa_cli`:

```
add_network
set_network 0 ssid "YOUR_WIFI_SSID"
set_network 0 psk "YOUR_WIFI_PASSWORD"
enable_network 0
quit
```

Wait a few seconds, then verify:

```bash
ping -c 3 nixos.org
```

If `wpa_cli` is not available, try `nmcli` instead:

```bash
nmcli device wifi connect "YOUR_WIFI_SSID" password "YOUR_WIFI_PASSWORD"
```

---

## Step 2: Prepare the LUKS Password File

Disko reads the LUKS passphrase from a file. Create it:

```bash
echo -n "YOUR_LUKS_PASSWORD" > /tmp/luks-password
```

**Important:** Use `-n` to avoid a trailing newline. Remember this password — you will need it every boot to unlock the drive.

---

## Step 3: Get Your Flake

### Option A: From a USB stick

```bash
mkdir -p /mnt-usb
mount /dev/sdX1 /mnt-usb   # replace sdX1 with your USB partition
```

### Option B: Clone from git

```bash
nix-shell -p git
git clone https://YOUR_REPO_URL /tmp/nixos-config
```

### Option C: Copy from current NixOS drive (nvme2n1)

```bash
mkdir -p /mnt-src
mount /dev/nvme2n1p2 /mnt-src   # may need LUKS unlock first
cp -r /mnt-src/home/thinky/Projects/NixOS /tmp/nixos-config
umount /mnt-src
```

---

## Step 4: Run Disko

**WARNING: This will ERASE everything on nvme1n1 (the BitLocker/Windows drive).**

```bash
sudo nix run github:nix-community/disko -- \
  --mode disko \
  /path/to/unified/hosts/M90aPro/disko.nix
```

Replace `/path/to/unified` with the actual path (e.g., `/tmp/nixos-config` or `/mnt-usb/NixOS/unified`).

Disko will:
1. Partition nvme1n1 (GPT: ESP + LUKS)
2. Create the LUKS container (using /tmp/luks-password)
3. Create LVM volume group "pool" with root and home logical volumes
4. Format everything (FAT32 for ESP, ext4 for root and home)
5. Mount everything under /mnt

Verify:

```bash
lsblk /dev/nvme1n1
```

Expected output:

```
nvme1n1          238.5G disk
├─nvme1n1p1        1G   part  /mnt/boot
└─nvme1n1p2      237.5G part
  └─crypted      237.5G crypt
    ├─pool-root  100G   lvm   /mnt
    └─pool-home  137.5G lvm   /mnt/home
```

---

## Step 5: Generate Hardware Config

```bash
sudo nixos-generate-config --no-filesystems --root /mnt
```

`--no-filesystems` is important because disko manages the filesystem/mount configuration. This generates `/mnt/etc/nixos/hardware-configuration.nix` with your kernel modules and hardware detection.

Copy the generated hardware config to your flake if needed, but make sure to keep the disko import instead of the filesystem declarations.

---

## Step 6: Install NixOS

```bash
sudo nixos-install --flake /path/to/unified#M90aPro --root /mnt
```

When prompted, set the root password.

---

## Step 7: Clean Up and Reboot

```bash
rm /tmp/luks-password
reboot
```

Select nvme1n1 from BIOS/GRUB. You will be prompted for the LUKS passphrase during boot.

---

## Post-Install: Integration with Flake

To make disko manage mounts declaratively, import `disko.nix` in your host config.

Edit `hosts/M90aPro/default.nix`:

```nix
{ ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./nvidia-prime.nix
    ./disko.nix
  ];

  networking.hostName = "M90aPro";
}
```

Then remove the `fileSystems` and `boot.initrd.luks.devices` entries from
`hardware-configuration.nix` since disko handles those.

---

## Troubleshooting

### "Device /dev/nvme1n1 not found"

Check available drives:

```bash
lsblk
```

### WiFi not connecting

Try restarting the service:

```bash
sudo systemctl restart wpa_supplicant
```

Or use `iwctl` if `iwd` is available on the installer:

```bash
iwctl station wlan0 scan
iwctl station wlan0 connect "YOUR_WIFI_SSID"
```

### LUKS password rejected at boot

The password you entered in `/tmp/luks-password` is the one LUKS expects.
If you used `echo` without `-n`, a newline was appended. You would then
need to type your password followed by Enter (the newline is part of it).
To fix, boot the installer again and re-run disko with the correct password.
