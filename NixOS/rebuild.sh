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
    X299      Build for X299 desktop
    M90aPro   Build for M90aPro laptop
    auto      Auto-detect based on hostname (default)

EXAMPLES:
    $0                    # Auto-detect host and switch
    $0 switch X299        # Switch X299 to new configuration
    $0 test M90aPro       # Test M90aPro configuration
    $0 update             # Update flake and rebuild
    $0 clean              # Clean old generations

This script always uses the flake at: $SCRIPT_DIR
Current hostname: $CURRENT_HOST
EOF
}

# Parse command line arguments
COMMAND=${1:-switch}
HOST=${2:-auto}

# Auto-detect host if needed
if [ "$HOST" = "auto" ]; then
    case "$CURRENT_HOST" in
        X299|M90aPro)
            HOST=$CURRENT_HOST
            print_info "Auto-detected host: $HOST"
            ;;
        *)
            print_error "Unknown hostname: $CURRENT_HOST"
            print_error "Please specify either 'X299' or 'M90aPro'"
            exit 1
            ;;
    esac
fi

# Validate host
if [ "$HOST" != "X299" ] && [ "$HOST" != "M90aPro" ]; then
    print_error "Invalid host: $HOST"
    print_error "Must be either 'X299' or 'M90aPro'"
    exit 1
fi

# Change to script directory
cd "$SCRIPT_DIR"
print_info "Working directory: $SCRIPT_DIR"

# Execute based on command
case "$COMMAND" in
    switch|test|boot|build)
        print_info "Running: sudo nixos-rebuild $COMMAND --flake .#$HOST"
        sudo nixos-rebuild "$COMMAND" --flake ".#$HOST"
        print_success "NixOS rebuild $COMMAND completed for $HOST"
        ;;

    update)
        print_info "Updating flake inputs..."
        nix flake update
        print_success "Flake inputs updated"

        print_info "Rebuilding with updated inputs..."
        sudo nixos-rebuild switch --flake ".#$HOST"
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