# Scramble encrypted folder on all NixOS hosts

The shared `home.nix` installs rclone and the same user services on X299,
X299-SSD, M90aPro, and PortableSSD. The working folder is
`~/Documents/Scramble Sync`; `~/Scramble Private` is a read-only decrypted
view of its cloud copy. The raw `EncryptedSync` folder in Scramble contains
rclone-encrypted names and files.

M90aPro already has a signed-in Scramble Desktop and an initialized sync.
Its WebDAV service stays on `127.0.0.1:1900`. The other hosts use the
official Scramble CLI to serve WebDAV on their own loopback address. Each
host must log in to the same Scramble account locally.

## Set up another host

1. Boot that host, update its `~/Projects` checkout with `git pull --ff-only`,
   then run `sudo nixos-rebuild switch --flake ~/Projects/NixOS#HOST`, replacing
   `HOST` with `X299`, `X299-SSD`, or `PortableSSD`. This installs the shared
   rclone units and helper commands.
2. Run `scramble-host-prepare` in a terminal on that host. It installs the
   pinned Scramble CLI, prompts for your Scramble login locally, generates
   separate local WebDAV credentials, and starts the loopback WebDAV service.
3. From M90aPro, run `scramble-transfer-crypt SSH_HOST`, replacing `SSH_HOST`
   with a working SSH name or address for the destination. SSH host-key
   verification must already work. This transfers **only** the rclone crypt
   settings. It does not copy the M90aPro WebDAV password or Scramble login.
4. On the destination host, run `scramble-sync-init`. It checks both rclone
   remotes, copies the cloud access marker, performs the first two-way sync,
   and starts the timer and decrypted mount.

Repeat steps 1–4 for each additional host. The hosts do not need to be
online at the same time to exchange files through Scramble Cloud.

## Use and verify

Edit files in `~/Documents/Scramble Sync`. The five-minute timer carries
edits and deletions in both directions. Browse `~/Scramble Private` to see
the cloud copy decrypted. Check the timer with
`systemctl --user list-timers scramble-private-sync.timer`, or run a sync
immediately with `systemctl --user start scramble-private-sync.service`.
The AGS bar shows the Scramble icon with a green dot when the connection,
timer, decrypted mount, and last sync are healthy. Yellow means setup is
pending or a sync is running; red means a service stopped, the last sync failed,
or no sync succeeded in 15 minutes. Hover over it for details, or run
`scramble-sync-status` in a terminal.
The indicator checks local service state; a new network failure appears after
the next sync attempt.

These are user services. They start automatically when you log in; M90aPro's
Scramble Desktop and the decrypted mount need a graphical session. They do not
sync before login. There is no separate crypt daemon: rclone encrypts uploads
and decrypts downloads as each sync or mount request runs.

If two hosts edit the same file before syncing, rclone may preserve both as
conflict copies. The timer uses downloaded hashes because this WebDAV
backend does not provide usable hashes, so a large folder can incur
substantial traffic. Earlier versions removed during a sync are kept in
`~/Documents/.Scramble Sync History` or the encrypted cloud `History` folder.

Keep `~/.config/rclone/rclone.conf` private and back it up securely: its
lightly obscured crypt keys are needed to decrypt this folder. No keys are
stored in the flake or Nix store. The local working folder is plaintext
while the host is unlocked.
