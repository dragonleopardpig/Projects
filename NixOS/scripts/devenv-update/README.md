# devenv update prompt

Home Manager places `launch` at `~/.local/bin/devenv`, ahead of the Nix profile
and NixOS binaries in `PATH`. Direct terminal calls check GitHub's latest stable
release at most once a day. If a newer version exists, answer `y` to install or
upgrade the official `github:cachix/devenv/latest` Nix profile package; any
other answer keeps the installed version. If the check fails, it retries after
an hour and runs the installed version.

Automatic direnv calls and noninteractive commands skip the check. Set
`DEVENV_UPDATE_CHECK=1` for an immediate check or `DEVENV_NO_UPDATE_CHECK=1`
to skip one. `devenv update` still updates a project's `devenv.lock`; this
launcher updates the CLI package.
