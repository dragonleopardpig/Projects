# Agent Guidelines & Repository Workflow

## Git & Multi-Host Deployment Rules
- **Always Commit & Push**: When completing configuration changes, features, or fixes, always commit changes with descriptive commit messages and push to `origin/main`.
- **Make Available to All Hosts**: When modifying NixOS flake configurations (`/home/thinky/Projects/NixOS`), ensure changes are compatible with and evaluated for all hosts (`CRUCIAL-SSD`, `X299-SSD`, `M90aPro`, `PortableSSD`).
- **NixOS Verification**: Rebuild and test locally on the active machine using `rebuild.sh switch` (or `rebuild.sh boot` on PortableSSD).
