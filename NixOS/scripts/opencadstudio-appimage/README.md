# Open CAD Studio AppImage on NixOS

Home Manager installs these scripts on each configured NixOS host under
`~/.local/libexec/opencadstudio-appimage/`. The graphical app menu launches
`launch`. It checks the latest official
release on GitHub, offers to download it, verifies the release's SHA-256 digest,
and opens the downloaded AppImage through NixOS's `appimage-run`. If the network
is unavailable or you decline an update, it opens the current download. Before
the first download, it opens the existing NixOS package.

To download an update manually, run
`~/.local/libexec/opencadstudio-appimage/update`. To open the installed AppImage
without checking for updates, run
`~/.local/libexec/opencadstudio-appimage/run`.

The AppImages are stored under `~/.local/share/opencadstudio-appimage/` and
update logs under `~/.local/state/opencadstudio-appimage/`. On M90aPro, activate
the NixOS and Home Manager changes with:

```sh
sudo nixos-rebuild switch --flake /home/thinky/Projects/NixOS#M90aPro
```
