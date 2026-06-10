#!/usr/bin/env bash

# NixOS rebuild helper script for unified configuration
# This script can be run from anywhere and will always use the correct flake

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Detect hostname
CURRENT_HOST=$(hostname)

# Function to print colored output
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to show usage
show_usage() {
    cat << EOF
Usage: $0 [OPTION] [HOST]

Rebuild NixOS configuration from unified flake.

OPTIONS:
    switch    Build and switch to new configuration (default)
    test      Build and test new configuration (rollback on reboot)
    boot      Build and set as boot default (switch on next boot)
    build     Build only, don't activate
    update    Update flake inputs before building
    clean     Clean old generations and collect garbage

HOST:
    X299        Build for X299 desktop
    X299-SSD    Build for X299 external SSD clone
    M90aPro     Build for M90aPro laptop
    PortableSSD Build for the portable boot-anywhere SSD
    auto        Auto-detect based on hostname (default)

PortableSSD is special — it never uses 'switch' (that restarts the
display-manager and logs you out mid-rebuild):
  * Run ON the PortableSSD  -> uses 'boot' + offers a reboot.
  * Run from another host    -> builds here and installs onto the
                                mounted PortableSSD disk (no logout).

EXAMPLES:
    $0                          # Auto-detect host and switch
    $0 switch X299              # Switch X299 to new configuration
    $0 test M90aPro             # Test M90aPro configuration
    $0 boot PortableSSD         # From any host: update the mounted PortableSSD
    $0 update                   # Update flake and rebuild
    $0 clean                    # Clean old generations

This script always uses the flake at: $SCRIPT_DIR
Current hostname: $CURRENT_HOST
EOF
}

# Build the PortableSSD config on THIS host and install it onto the mounted
# PortableSSD disk. Uses 'boot' semantics inside a chroot: it copies the closure,
# registers a new system generation, and writes the bootloader to the disk's ESP —
# but never activates services, so the host you're sitting at is untouched (no
# logout). Boot the PortableSSD afterwards to land on the new generation.
build_portablessd_mounted() {
    # Identifiers of THIS PortableSSD disk (decrypted ext4 root + its ESP).
    local PORTABLE_ROOT_UUID="39ecb7ec-6f24-4d0e-8558-26b8281fcc86"
    local PORTABLE_BOOT_UUID="931F-04BC"

    local MNT
    MNT=$(findmnt -n -o TARGET "UUID=$PORTABLE_ROOT_UUID" 2>/dev/null | head -1) || true
    if [ -z "$MNT" ]; then
        print_error "PortableSSD root (UUID=$PORTABLE_ROOT_UUID) is not mounted."
        print_error "Plug in + unlock the PortableSSD (open it in your file manager), then retry."
        exit 1
    fi
    print_info "PortableSSD root mounted at: $MNT"

    # The ESP must be mounted at <root>/boot for the bootloader install.
    local ESP_WAS_MOUNTED=1
    if ! findmnt -n "$MNT/boot" >/dev/null 2>&1; then
        ESP_WAS_MOUNTED=0
        print_info "Mounting PortableSSD ESP (UUID=$PORTABLE_BOOT_UUID) at $MNT/boot"
        sudo mount "/dev/disk/by-uuid/$PORTABLE_BOOT_UUID" "$MNT/boot"
    fi

    local AVAIL_MB
    AVAIL_MB=$(( $(df --output=avail -k "$MNT" | tail -1 | tr -d ' ') / 1024 ))
    print_info "Free space on the PortableSSD root: ${AVAIL_MB} MB"
    if [ "$AVAIL_MB" -lt 1024 ]; then
        print_warning "Under 1 GiB free. The closure delta is small, but run"
        print_warning "'nix-collect-garbage -d' on the PortableSSD after booting it."
    fi

    print_info "Building PortableSSD system closure on $CURRENT_HOST (native x86_64)..."
    local SYS
    SYS=$(nix build "$SCRIPT_DIR#nixosConfigurations.PortableSSD.config.system.build.toplevel" \
            --no-link --print-out-paths)
    print_success "Built: $SYS"

    print_info "Copying the closure into the PortableSSD store (only missing paths transfer)..."
    sudo nix copy --no-check-sigs --to "$MNT" "$SYS"

    print_info "Registering it as a new system generation on the PortableSSD..."
    sudo nix-env --profile "$MNT/nix/var/nix/profiles/system" --set "$SYS"

    print_info "Installing the bootloader inside the disk (boot mode — no activation, no logout)..."
    sudo nixos-enter --root "$MNT" -c "NIXOS_INSTALL_BOOTLOADER=1 $SYS/bin/switch-to-configuration boot"

    if [ "$ESP_WAS_MOUNTED" -eq 0 ]; then
        print_info "Unmounting the ESP we mounted at $MNT/boot"
        sudo umount "$MNT/boot" || print_warning "Could not unmount $MNT/boot (in use?)"
    fi

    print_success "PortableSSD updated from $CURRENT_HOST. Nothing on $CURRENT_HOST was activated."
    print_info "Boot the PortableSSD to use the new generation."
}

# Parse command line arguments
COMMAND=${1:-switch}
HOST=${2:-auto}

# Auto-detect host if needed
if [ "$HOST" = "auto" ]; then
    case "$CURRENT_HOST" in
        X299|X299-SSD|M90aPro|PortableSSD)
            HOST=$CURRENT_HOST
            print_info "Auto-detected host: $HOST"
            ;;
        *)
            print_error "Unknown hostname: $CURRENT_HOST"
            print_error "Please specify 'X299', 'X299-SSD', 'M90aPro', or 'PortableSSD'"
            exit 1
            ;;
    esac
fi

# Validate host
if [ "$HOST" != "X299" ] && [ "$HOST" != "X299-SSD" ] && [ "$HOST" != "M90aPro" ] && [ "$HOST" != "PortableSSD" ]; then
    print_error "Invalid host: $HOST"
    print_error "Must be 'X299', 'X299-SSD', 'M90aPro', or 'PortableSSD'"
    exit 1
fi

# Change to script directory
cd "$SCRIPT_DIR"
print_info "Working directory: $SCRIPT_DIR"

IMPURE_FLAG=""
if [ "$HOST" = "X299" ] || [ "$HOST" = "X299-SSD" ]; then
    IMPURE_FLAG="--impure"
    print_info "Using --impure for $HOST so local Euresys driver sources can be imported"
fi

# PortableSSD never uses 'switch' (it logs you out mid-rebuild). Route its
# build/activate commands to safe paths; clean/update/help fall through below.
if [ "$HOST" = "PortableSSD" ]; then
    case "$COMMAND" in
        switch|test|boot|build)
            if [ "$CURRENT_HOST" != "PortableSSD" ]; then
                print_info "You're on $CURRENT_HOST; target is PortableSSD."
                print_info "Building here and installing onto the mounted disk (no logout)."
                build_portablessd_mounted
            else
                if [ "$COMMAND" != "boot" ] && [ "$COMMAND" != "build" ]; then
                    print_warning "On the PortableSSD, '$COMMAND' restarts the display-manager and"
                    print_warning "logs you out mid-rebuild. Using 'boot' + reboot instead."
                    COMMAND="boot"
                fi
                print_info "Running: sudo nixos-rebuild $COMMAND --flake .#PortableSSD"
                sudo nixos-rebuild "$COMMAND" --flake ".#PortableSSD"
                print_success "NixOS '$COMMAND' completed for PortableSSD (no activation, no logout)."
                if [ "$COMMAND" = "boot" ]; then
                    read -p "Reboot now to use the new generation? (y/N) " -n 1 -r; echo
                    [[ $REPLY =~ ^[Yy]$ ]] && sudo reboot
                fi
            fi
            exit 0
            ;;
    esac
fi

# Execute based on command
case "$COMMAND" in
    switch|test|boot|build)
        print_info "Running: sudo nixos-rebuild $COMMAND $IMPURE_FLAG --flake .#$HOST"
        sudo nixos-rebuild "$COMMAND" $IMPURE_FLAG --flake ".#$HOST"
        print_success "NixOS rebuild $COMMAND completed for $HOST"
        ;;

    update)
        print_info "Updating flake inputs..."
        nix flake update
        print_success "Flake inputs updated"

        print_info "Rebuilding with updated inputs..."
        sudo nixos-rebuild switch $IMPURE_FLAG --flake ".#$HOST"
        print_success "NixOS rebuild completed with updated inputs for $HOST"
        ;;

    clean)
        print_warning "This will delete old generations and collect garbage"
        read -p "Continue? (y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            print_info "Deleting old generations..."
            sudo nix-collect-garbage -d
            print_success "Garbage collection completed"
        else
            print_info "Cancelled"
        fi
        ;;

    help|--help|-h)
        show_usage
        exit 0
        ;;

    *)
        print_error "Unknown command: $COMMAND"
        echo
        show_usage
        exit 1
        ;;
esac

# Show current system info
echo
print_info "Current system generation:"
nixos-version
echo
print_info "Current flake location: $SCRIPT_DIR"

# Reminder about /etc/nixos
if [ -d /etc/nixos ] && [ ! -L /etc/nixos ]; then
    print_warning "/etc/nixos exists and is not a symlink."
    print_warning "Remember: When using --flake, /etc/nixos is NOT used."
    print_warning "This build used only: $SCRIPT_DIR"
fi
