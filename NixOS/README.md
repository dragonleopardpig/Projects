# Unified NixOS Configuration for X299 and M90aPro

This is a minimal unified configuration for managing both X299 (desktop) and M90aPro (laptop) with:
- **Identical** `configuration.nix` and `home.nix` for both hosts
- Only essential host-specific differences (hostname, hardware, NVIDIA setup)

## Structure

```
NixOS/
├── flake.nix                # Main flake defining both hosts
├── configuration.nix         # SHARED system configuration (identical for both)
├── home.nix                 # SHARED home-manager configuration (identical for both)
└── hosts/
    ├── X299/
    │   ├── default.nix              # Sets hostname to "X299"
    │   ├── hardware-configuration.nix # Hardware auto-generated config
    │   └── nvidia.nix               # Standard NVIDIA config (single GPU)
    └── M90aPro/
        ├── default.nix              # Sets hostname to "M90aPro"
        ├── hardware-configuration.nix # Hardware auto-generated config
        └── nvidia-prime.nix         # NVIDIA Prime/Optimus (Intel + NVIDIA)
```

## Key Features

- **Single shared configuration**: Both hosts use the exact same `configuration.nix` and `home.nix`
- **Minimal host differences**: Only hostname, hardware detection, and NVIDIA setup differ
- **NixOS 25.11**: Using latest NixOS version
- **Hyprland + HyprPanel**: Wayland compositor with modern panel
- **State version**: Both configuration.nix and home.nix use `25.11`

## Host-Specific Differences

| Component | X299 | M90aPro |
|-----------|------|---------|
| Hostname | "X299" | "M90aPro" |
| Hardware | Desktop hardware | Laptop hardware |
| NVIDIA | Single GPU (nvidia.nix) | Optimus/Prime (nvidia-prime.nix) |

## ⚠️ Important: Flake Directory vs /etc/nixos

**When using `--flake`, NixOS completely ignores `/etc/nixos/`!**

- The flake build ONLY uses files from the flake directory (this unified folder)
- `/etc/nixos/` is NOT required and NOT used when building with `--flake`
- You can work directly from `~/Projects/NixOS/` without issues
- If both directories exist but differ, only the flake directory matters

## Usage

### Using the Helper Script (Easiest)

```bash
cd ~/Projects/NixOS

# Auto-detect host and rebuild
./rebuild.sh

# Specific operations
./rebuild.sh switch X299      # Switch X299 to new config
./rebuild.sh test M90aPro     # Test M90aPro config
./rebuild.sh update           # Update flake and rebuild
./rebuild.sh clean            # Clean old generations
```

### Initial Setup

1. **Work from your chosen directory**:
   ```bash
   cd ~/Projects/NixOS
   # You can work directly from here, no need to copy to /etc/nixos
   ```

2. **Generate hardware configuration** (on each machine):
   ```bash
   # On X299:
   sudo nixos-generate-config --show-hardware-config > hosts/X299/hardware-configuration.nix

   # On M90aPro:
   sudo nixos-generate-config --show-hardware-config > hosts/M90aPro/hardware-configuration.nix
   ```

3. **For M90aPro ONLY - Update NVIDIA Prime Bus IDs**:
   ```bash
   # Find your PCI bus IDs:
   lspci | grep VGA

   # Edit hosts/M90aPro/nvidia-prime.nix and update:
   intelBusId = "PCI:X:X:X";  # Your Intel GPU
   nvidiaBusId = "PCI:X:X:X"; # Your NVIDIA GPU
   ```

### Building Configuration

**For X299 desktop**:
```bash
cd ~/Projects/NixOS  # or wherever your unified directory is
sudo nixos-rebuild switch --flake .#X299
```

**For M90aPro laptop**:
```bash
cd ~/Projects/NixOS  # or wherever your unified directory is
sudo nixos-rebuild switch --flake .#M90aPro
```

### Updating

Update all flake inputs:
```bash
nix flake update
sudo nixos-rebuild switch --flake .#X299    # or .#M90aPro
```

## Making Changes

### For BOTH hosts (most common):
- Edit `configuration.nix` for system-wide changes
- Edit `home.nix` for user environment changes
- Both hosts will get the same changes

### For specific host only (rare):
- X299: Edit files in `hosts/X299/`
- M90aPro: Edit files in `hosts/M90aPro/`

## NVIDIA Configuration

### X299 (Desktop)
- Standard single NVIDIA GPU configuration
- Always uses NVIDIA for rendering
- Located in `hosts/X299/nvidia.nix`

### M90aPro (Laptop)
- NVIDIA Optimus/Prime configuration (Intel + NVIDIA)
- Default: **Sync mode** (best performance, both GPUs always on)
- Located in `hosts/M90aPro/nvidia-prime.nix`

To switch M90aPro to **Offload mode** (better battery life):
1. Edit `hosts/M90aPro/nvidia-prime.nix`
2. Comment out `sync.enable = true;`
3. Uncomment the offload configuration block
4. Rebuild: `sudo nixos-rebuild switch --flake .#M90aPro`

## Quick Commands

Both hosts have the same aliases defined in `home.nix`:

```bash
rebuild     # Rebuilds NixOS configuration
gc          # Git commit
ls          # Enhanced ls with icons
```

## Troubleshooting

### Check current hostname:
```bash
hostname
```

### Verify NVIDIA is working:
```bash
nvidia-smi
```

### For M90aPro Prime setup, verify bus IDs:
```bash
lspci | grep VGA
```

### Test offload mode (M90aPro only, if enabled):
```bash
nvidia-offload glxgears
```

## Benefits of This Setup

1. **Minimal maintenance**: One set of configs for both machines
2. **Easy updates**: Change once, applies to both
3. **Clear separation**: Host-specific stuff is isolated and minimal
4. **Version control friendly**: Can track changes easily
5. **Predictable**: Both machines behave nearly identically

## Important Notes

- The timezone is set to "Asia/Singapore" in configuration.nix
- Git user is set to "dragonleopardpig" in home.nix
- Auto-login is disabled (no autoLogin configuration)
- Both use Hyprland with HyprPanel
- Weather API key for HyprPanel should be in `~/.config/secrets/weather-api-key`
