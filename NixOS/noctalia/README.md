# Noctalia Suite

All hosts offer **Noctalia Shell with Umbriel** and the previous **Hyprland +
AGS** desktop at login. M90aPro and CRUCIAL-SSD use Noctalia Greeter; other
hosts retain SDDM. Strata remains a separate host package where enabled.

The former AGS bridge bar trial and nested desktop/greeter previews have been
removed. This flake contains the desktop session and its validation tools.

- [Desktop configuration](suite/README.md)
- [Daily shortcuts](suite/SHORTCUTS.md)
- [OLO-Neon theme](suite/theme/README.md)
- [Deployment and rollback](DEPLOYMENT.md)

The bar centers the active task title and places the clock on the right.
OLO-inspired teal fills provide readable controls; neon magenta accents the
window outlines and wallpaper curves. Display preferences persist in
`~/.config/umbriel/outputs.toml`.

Build and install the host for the next boot from `~/Projects/NixOS`:

```sh
./rebuild.sh boot CRUCIAL-SSD
```

Choose **Noctalia Suite** at login. From a TTY, the installed session can also
be started with `nix run path:./noctalia#session`.

Configuration checks and the isolated lock/power regression are available
without changing the running desktop:

```sh
nix flake check path:./noctalia --accept-flake-config
nix run path:./noctalia#check-lock --accept-flake-config
```

The lock/power check uses a headless display, private buses, and temporary
state. It does not lock or blank the host desktop.
