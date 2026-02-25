# Euresys eGrabber on NixOS — Setup Guide

On Ubuntu/Mint, you run `install.sh` and everything works. On NixOS, the vendor
installer can't modify the system (no FHS layout, no `/lib`, no `modprobe.d`, no
`dkms`). Every piece the installer does automatically must be handled explicitly.

This guide documents all the steps required and the problems solved along the way.

## Overview of What's Needed

| Component | Ubuntu/Mint | NixOS |
|---|---|---|
| Kernel modules | `dkms` auto-builds | Custom Nix derivation per module |
| Device nodes (`/dev/coaxlink0`) | `modprobe.d` install hook runs `createdev` | Systemd oneshot service |
| Shared libraries for GUI | Already in `/usr/lib` | `buildFHSEnv` with explicit lib list |
| Qt5 plugin path for Studio | Hardcoded Ubuntu build path works | `qt.conf` created via activation script |
| Memento tracing | `install.sh` handles everything | Separate kernel module built first, symvers exported |

## Prerequisites

- NixOS with flake-based configuration
- Downloads from Euresys website:
  - `egrabber-linux-x86_64-<version>` (eGrabber drivers + Studio)
  - `memento-linux-x86_64-<version>` (Memento tracing — optional but recommended)

## Step 1: Copy Driver Source into Your NixOS Config

Nix flakes can only see files within the flake tree, so the vendor source must be
copied into your NixOS configuration directory.

```bash
# From the eGrabber package — copy drivers/ contents (headers + linux/ + precompiled/)
mkdir -p /path/to/nixos/hosts/X299/egrabber-drivers
cp -r ~/Downloads/egrabber-linux-x86_64-26.01.0.2/drivers/* \
      /path/to/nixos/hosts/X299/egrabber-drivers/

# From the Memento package — same structure
mkdir -p /path/to/nixos/hosts/X299/memento-drivers
cp -r ~/Downloads/memento-linux-x86_64-26.01.0.2/drivers/* \
      /path/to/nixos/hosts/X299/memento-drivers/
```

**Important:** You must copy the entire `drivers/` directory, not just `drivers/linux/`.
The C source files in `linux/` include headers via `#include "../os_debug.h"` — those
headers live in the parent `drivers/` directory.

## Step 2: Fix CRLF Line Endings

The vendor source files have Windows-style CRLF line endings that break the Nix
sandbox build (bash interprets `\r` as part of commands). Fix them locally:

```bash
find /path/to/nixos/hosts/X299/egrabber-drivers -type f \
  \( -name "*.c" -o -name "*.h" -o -name "Makefile*" -o -name "*.mk" \) \
  -exec sed -i 's/\r$//' {} +

find /path/to/nixos/hosts/X299/memento-drivers -type f \
  \( -name "*.c" -o -name "*.h" -o -name "Makefile*" -o -name "*.mk" \) \
  -exec sed -i 's/\r$//' {} +
```

The NixOS module also patches CRLF during `patchPhase` as a safety net.

## Step 3: Git-Track the Files

Nix flakes only see git-tracked files:

```bash
cd /path/to/nixos
git add hosts/X299/egrabber-drivers/ hosts/X299/memento-drivers/
```

## Step 4: Create the NixOS Module

Create `hosts/X299/egrabber.nix`. The full file is included at the end of this
guide. It handles five things:

### 4a. Building Kernel Modules

The Euresys Makefile has a non-standard structure: the `default` target (line ~101)
iterates over a `MODULES` variable in a bash for-loop, calling kbuild per-module:

```makefile
# Euresys Makefile structure (simplified)
default:
    for m in $(MODULES); do
        $(MAKE) -C $(KDIR) M=$(PWD) MODULE=$$m modules
    done
```

This means you must invoke the Makefile's own `default` target, NOT call kbuild
directly. The correct invocation is:

```
make -C linux KDIR=/path/to/kernel/build MODULES="memento"
```

NOT:

```
make -C /path/to/kernel/build M=$(pwd)/linux MODULES="memento"  # WRONG — bypasses the for-loop
```

The Makefile also hardcodes `SHELL:=/bin/bash` which doesn't exist in the Nix
sandbox, so we patch it to use `${pkgs.bash}/bin/bash`.

Memento must be built first because eGrabber's `coaxlink` module depends on
Memento's exported symbols (`Module.symvers`). The eGrabber Makefile already
supports `PATH_TO_MEMENTO_MODULE_SYMVERS` to pass this path.

### 4b. Creating Device Nodes

On Ubuntu, the vendor installs a modprobe.d config that runs a `createdev` script
after each module loads. This script reads `/proc/devices` to get the dynamically
assigned major number, then creates `/dev/coaxlink0`..`/dev/coaxlink15` etc. via
`mknod`.

NixOS doesn't use `/etc/modprobe.d/` in the standard way. Instead, we create a
systemd oneshot service (`euresys-createdev`) that runs after
`systemd-modules-load.service` and performs the same `mknod` logic.

### 4c. FHS Environment for Vendor Installers and GUI Tools

The vendor's `install.sh` and precompiled binaries expect a standard Linux FHS
layout (`/usr/lib`, `/lib64/ld-linux-x86-64.so.2`, etc.). We use `buildFHSEnv` to
create a chroot-like environment with all required libraries.

Key library groups needed:
- **GTK2**: for Memento GUI (`libgtk-x11-2.0.so.0`, glib, cairo, pango, etc.)
- **XCB + xkbcommon**: for the bundled Qt5 xcb platform plugin
- **Qt5**: base libraries (the vendor bundles its own Qt5 but needs system xcb glue)
- **X11**: standard X11 libraries for XWayland rendering

### 4d. Qt Plugin Path Fix for eGrabber Studio

eGrabber Studio bundles its own Qt 5.12.4 libraries but has a hardcoded plugin
search path from the vendor's Ubuntu build machine (`/home/ubuntu/hg/qt/Qt/5.12.4/gcc_64/plugins`).
It also searches `<binary_dir>/platforms/` but the plugins are actually installed at
`<binary_dir>/plugins/platforms/`.

The fix is a `qt.conf` file placed next to the `studio` binary:

```ini
[Paths]
Plugins = plugins
```

This is created automatically by an activation script that runs on every
`nixos-rebuild switch`.

### 4e. Persistent Directories

The module creates `/opt/euresys` and `/lib/firmware/euresys` via tmpfiles rules
so the vendor installer has somewhere to write.

## Step 5: Import the Module

In your host's `default.nix`:

```nix
{
  imports = [
    ./hardware-configuration.nix
    ./nvidia.nix
    ./egrabber.nix
  ];
  networking.hostName = "X299";
}
```

## Step 6: Build and Switch

```bash
sudo nixos-rebuild switch --flake .#X299
```

After switching (or rebooting), verify:

```bash
# Kernel modules loaded
lsmod | grep -E "memento|coaxlink"
# Expected: memento (used by coaxlink), coaxlink

# Device nodes created
ls /dev/coaxlink0 /dev/memento0
# Expected: both exist with mode 666

# dmesg confirms device detection
sudo dmesg | grep coaxlink
# Expected: "1 device detected"
```

## Step 7: Run the Vendor Installer (Inside FHS)

The vendor's `install.sh` must run inside the FHS environment:

```bash
cd ~/Downloads/egrabber-linux-x86_64-26.01.0.2
euresys-fhs -c "sudo bash install.sh"

cd ~/Downloads/memento-linux-x86_64-26.01.0.2
euresys-fhs -c "sudo bash install.sh"
```

The installers will copy runtime files, libraries, and tools to `/opt/euresys/`.

## Step 8: Rebuild Again (for qt.conf)

After running the vendor installer, rebuild to trigger the activation script that
creates `qt.conf`:

```bash
sudo nixos-rebuild switch --flake .#X299
```

## Step 9: Launch the GUI Tools

```bash
# eGrabber Studio
euresys-fhs -c "QT_QPA_PLATFORM=xcb /opt/euresys/egrabber/studio/studio"

# Memento viewer
euresys-fhs -c "/opt/euresys/memento/bin/x86_64/memento"
```

## Step 10: Compile and Run the C++ Sample Programs

eGrabber ships sample programs under `egrabber-linux-x86_64-<version>/samples/cpp/`.
On Ubuntu these "just work" with `make && ./egrabber-samples`. On NixOS, you cannot
nest inside the FHS environment because the samples are compiled with GCC from Nix
(which uses the NixOS dynamic linker, not the FHS one). Instead, use a devenv
environment with the correct `LD_LIBRARY_PATH`.

### The Core Problem: dlopen and nix-ld

The eGrabber C++ API is header-only. At runtime, it `dlopen()`s the vendor shared
library (`libegrabber.so`) and the GenTL producer (`coaxlink.cti`). These vendor
binaries are unpatched ELF files built for standard Linux — their dependencies
(glibc, libstdc++, etc.) live at paths that don't exist on NixOS.

NixOS has **nix-ld** to handle this: it provides `/lib64/ld-linux-x86-64.so.2` and
sets `NIX_LD_LIBRARY_PATH` pointing to `/run/current-system/sw/share/nix-ld/lib`.
But here's the catch:

- Programs launched via nix-ld's linker (unpatched vendor binaries) use
  `NIX_LD_LIBRARY_PATH` automatically.
- Programs compiled on NixOS use the **NixOS dynamic linker** (a Nix store path).
  When those programs `dlopen()` vendor libraries, the NixOS linker does NOT consult
  `NIX_LD_LIBRARY_PATH`. The vendor library's dependencies silently fail to resolve,
  and GenAPI initialization fails with **GenTL error -1002** ("Module or resource is
  not initialized").

**The fix:** Set `LD_LIBRARY_PATH` to include the nix-ld library directory so the
NixOS dynamic linker can find the standard libraries that vendor code needs:

```bash
export LD_LIBRARY_PATH="/run/current-system/sw/share/nix-ld/lib:/opt/euresys/egrabber/lib/x86_64"
```

### devenv.nix for C++ eGrabber Development

Use [devenv](https://devenv.sh) with direnv to manage the environment. Create a
`devenv.nix` in your C++ project directory:

```nix
{ pkgs, lib, config, inputs, ... }:

{
  env.LD_LIBRARY_PATH = "/run/current-system/sw/share/nix-ld/lib:/opt/euresys/egrabber/lib/x86_64";

  packages = with pkgs; [
    cmake
    gcc
    pkg-config
  ];

  languages.cplusplus.enable = true;
}
```

The two critical paths in `LD_LIBRARY_PATH`:
- `/run/current-system/sw/share/nix-ld/lib` — glibc, libstdc++, libm, etc. for
  vendor library dependencies
- `/opt/euresys/egrabber/lib/x86_64` — libegrabber.so, coaxlink.cti

### Fixing the Sample Code

The vendor samples ship configured for GigE Vision cameras (`Gigelink()` producer)
and use `cameras(0)` for camera-oriented discovery. For CoaxLink hardware:

1. **Remove explicit producer selection** — `EGenTL genTL;` (no args) defaults to
   CoaxLink when `EURESYS_DEFAULT_GENTL_PRODUCER` is unset. Alternatively, use
   `EGenTL genTL(Coaxlink());`.

2. **Use `egrabbers(0)` instead of `cameras(0)`** — `cameras(0)` requires the
   JavaScript camera-configuration runtime (configurator.js → CXP-configurator.js →
   auto.js) which may fail outside the full eGrabber Studio environment. Using
   `egrabbers(0)` with `discover()` (or `discover(false)` for grabber-only
   discovery) is more robust.

Files that need `Gigelink()` → default or `Coaxlink()`:
- `101-singleframe.cpp`, `102-action-grab.cpp`
- `270-multicast-master.cpp`, `271-multicast-receiver.cpp`

Files that need `cameras(0)` → `egrabbers(0)`:
- `100-grabn.cpp`, `105-area-scan-grabn.cpp`, `106-line-scan-grabn.cpp`
- `241-multi-part.cpp`, `700-memento.cpp`
- `500-cuda-*.cpp`, `502-cuda-*.cpp`, `503-cuda-*.cpp`, `504-cuda-*.cpp`

Example fix for `105-area-scan-grabn.cpp`:

```cpp
static void sample() {
    EGenTL genTL;                          // default = CoaxLink
    EGrabberDiscovery egrabberDiscovery(genTL);
    egrabberDiscovery.discover();           // full discovery (camera + grabber)
    if (egrabberDiscovery.egrabberCount() == 0) {
        Tools::log("No grabber found");
        return;
    }
    EGrabber<CallbackOnDemand> grabber(egrabberDiscovery.egrabbers(0));
    FormatConverter converter(genTL);
    // ... rest of sample unchanged
}
```

### Build and Run

```bash
cd /path/to/egrabber-snippets

# Build (skip CUDA samples if nvcc headers aren't configured)
make NVCC=/nonexistent

# Run
./egrabber-samples
```

Successful output for sample 105:

```
Running "105-area-scan-grabn"
egrabberCount: 1
cameraCount: 1
DeviceID: Device0
```

Captured frames are saved to `output/105-area-scan-grabn/frame.NNN.jpeg`.

### How to Debug GenTL -1002 Errors

If you see `GenTL error -1002, GenapiGetString: Module or resource is not
initialized`, the GenAPI XML parser inside the vendor library failed to load — almost
always a missing library dependency. Use this diagnostic program:

```cpp
#include <EGrabber.h>
#include <iostream>
using namespace Euresys;

int main() {
    try {
        EGenTL genTL;
        EGrabberDiscovery disc(genTL);
        disc.discover(false);
        std::cout << "egrabberCount: " << disc.egrabberCount() << std::endl;

        if (disc.egrabberCount() > 0) {
            EGrabber<CallbackOnDemand> grabber(disc.egrabbers(0));
            // These all fail with -1002 if LD_LIBRARY_PATH is wrong:
            std::cout << "DeviceID: "
                      << grabber.getString<DeviceModule>("DeviceID") << std::endl;
            std::cout << "InterfaceID: "
                      << grabber.getString<InterfaceModule>("InterfaceID") << std::endl;
            std::cout << "TLVendorName: "
                      << grabber.getString<SystemModule>("TLVendorName") << std::endl;
        }
    } catch (std::exception &e) {
        std::cerr << "Exception: " << e.what() << std::endl;
        return 1;
    }
    return 0;
}
```

Compile with:
```bash
g++ -std=c++14 -I/opt/euresys/egrabber/include -o test-gentl test-gentl.cpp \
    -L/opt/euresys/egrabber/lib/x86_64 -legrabber -ldl -lpthread
```

If discovery succeeds (egrabberCount > 0) but getString fails with -1002, your
`LD_LIBRARY_PATH` is missing the nix-ld path.

## Troubleshooting

### "No such file or directory" on a binary that clearly exists
The binary's ELF interpreter (`/lib64/ld-linux-x86-64.so.2`) doesn't exist on
NixOS. Run it inside `euresys-fhs`.

### Studio launches but doesn't detect the grabber card
Check that `/dev/coaxlink0` exists. If not:
```bash
sudo systemctl restart euresys-createdev
```

### Studio crashes silently (exit code 134)
Missing Qt platform plugin. Verify `qt.conf` exists:
```bash
cat /opt/euresys/egrabber-linux-x86_64-*/studio/qt.conf
```
If missing, rebuild (`nixos-rebuild switch`) to trigger the activation script.

### Build fails with "No rule to make target '.mod'"
You're calling kbuild directly instead of the Makefile's `default` target.
Use `make -C linux KDIR=... MODULES=...`, not `make -C $KDIR M=... MODULES=...`.

### Build fails with "\r: command not found"
CRLF line endings. Run `sed -i 's/\r$//'` on the source files (Step 2).

### GenTL error -1002 when running C++ samples
The GenAPI module fails to initialize. Discovery works (finds the grabber) but any
GenAPI call (getString, getInteger, runScript) fails. This means the vendor library's
internal dependencies can't be resolved.

**Fix:** Ensure `LD_LIBRARY_PATH` includes `/run/current-system/sw/share/nix-ld/lib`.
See Step 10 for details.

**Why it happens:** NixOS-compiled programs use the NixOS dynamic linker, which
doesn't consult `NIX_LD_LIBRARY_PATH`. When those programs `dlopen()` the vendor
`libegrabber.so`, its transitive dependencies (glibc, libstdc++) must be findable
via `LD_LIBRARY_PATH`.

### Sample crashes with `vector::_M_range_check` (size 0)
The `cameras(0)` or `egrabbers(0)` call returned an empty list. Causes:
- Using `cameras(0)` without JavaScript runtime support — switch to `egrabbers(0)`
- Using `Gigelink()` producer with CoaxLink hardware — remove the explicit producer
  or use `Coaxlink()`
- `LD_LIBRARY_PATH` missing — discovery partially works but the GenTL producer
  can't fully enumerate devices

### "memento support disabled (no backing)" in dmesg
The `memento` module must load before `coaxlink`. In the NixOS module,
`boot.kernelModules` lists them in order: `[ "memento" "coaxlink" "grablink" ]`.

## Complete egrabber.nix

```nix
# Euresys Memento + eGrabber kernel drivers for CoaxLink/GrabLink PCIe frame grabber
{ config, lib, pkgs, ... }:

let
  kernelPackages = config.boot.kernelPackages;
  kdir = "${kernelPackages.kernel.dev}/lib/modules/${kernelPackages.kernel.modDirVersion}/build";
  modDir = kernelPackages.kernel.modDirVersion;

  patchDriverSource = ''
    find . -type f \( -name "*.c" -o -name "*.h" -o -name "Makefile*" -o -name "*.mk" \) -exec sed -i 's/\r$//' {} +
    sed -i 's|SHELL:=/bin/bash|SHELL:=${pkgs.bash}/bin/bash|' linux/Makefile
  '';

  mementoKmod = pkgs.stdenv.mkDerivation {
    pname = "memento-kmod";
    version = "26.01.0.2";
    src = ./memento-drivers;
    nativeBuildInputs = kernelPackages.kernel.moduleBuildDependencies;
    dontConfigure = true;
    patchPhase = patchDriverSource;
    buildPhase = ''
      runHook preBuild
      make -C linux KDIR=${kdir} MODULES="memento" -j$NIX_BUILD_CORES
      runHook postBuild
    '';
    installPhase = ''
      mkdir -p $out/lib/modules/${modDir}/extra
      cp linux/memento.ko $out/lib/modules/${modDir}/extra/
      mkdir -p $out/drivers/linux
      cp linux/Module.symvers $out/drivers/linux/
    '';
  };

  egrabberKmod = pkgs.stdenv.mkDerivation {
    pname = "egrabber-kmod";
    version = "26.01.0.2";
    src = ./egrabber-drivers;
    nativeBuildInputs = kernelPackages.kernel.moduleBuildDependencies;
    dontConfigure = true;
    patchPhase = patchDriverSource;
    buildPhase = ''
      runHook preBuild
      make -C linux KDIR=${kdir} \
        MODULES="coaxlink grablink" \
        PATH_TO_MEMENTO_MODULE_SYMVERS=${mementoKmod}/drivers/linux/Module.symvers \
        -j$NIX_BUILD_CORES
      runHook postBuild
    '';
    installPhase = ''
      mkdir -p $out/lib/modules/${modDir}/extra
      cp linux/coaxlink.ko $out/lib/modules/${modDir}/extra/
      cp linux/grablink.ko $out/lib/modules/${modDir}/extra/
    '';
  };

  euresysFHS = pkgs.buildFHSEnv {
    name = "euresys-fhs";
    targetPkgs = pkgs: with pkgs; [
      gcc gnumake binutils
      kernelPackages.kernel.dev
      glibc zlib stdenv.cc.cc.lib libGL
      bash coreutils findutils gnugrep gnused gawk which file pciutils kmod udev
      gtk2 glib cairo pango gdk-pixbuf atk libsm libice expat libGLU
      libx11 libxext libxrender libxi libxrandr libxcursor libxfixes libxft
      libxtst libxcomposite libxdamage libxinerama
      freetype fontconfig dbus
      libxcb libxkbcommon xorg.libxkbfile
      qt5.qtbase qt6.qtbase qt6.qtwayland
    ];
    runScript = "bash";
  };
in
{
  boot.extraModulePackages = [ mementoKmod egrabberKmod ];
  boot.kernelModules = [ "memento" "coaxlink" "grablink" ];
  environment.systemPackages = [ euresysFHS ];

  systemd.tmpfiles.rules = [
    "d /opt/euresys 0755 root root -"
    "d /lib/firmware/euresys 0755 root root -"
  ];

  systemd.services.euresys-createdev = {
    description = "Create Euresys device nodes";
    after = [ "systemd-modules-load.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig.Type = "oneshot";
    serviceConfig.RemainAfterExit = true;
    script = ''
      create_devs() {
        driver=$1
        max=''${2:-15}
        major=$(${pkgs.gawk}/bin/awk -v d="$driver" '$2 == d {print $1}' /proc/devices)
        [ -z "$major" ] && return
        for i in $(${pkgs.coreutils}/bin/seq 0 $max); do
          ${pkgs.coreutils}/bin/mknod -m 666 /dev/$driver$i c $major $i 2>/dev/null || true
        done
      }
      create_devs memento
      create_devs coaxlink
      create_devs grablink
    '';
  };

  system.activationScripts.euresysQtConf = ''
    for dir in /opt/euresys/egrabber*/studio; do
      if [ -d "$dir/plugins/platforms" ] && [ ! -f "$dir/qt.conf" ]; then
        cat > "$dir/qt.conf" << EOF
    [Paths]
    Plugins = plugins
    EOF
      fi
    done
  '';
}
```
