# Scramble public and private folders on all NixOS hosts

The shared `home.nix` installs Scramble Desktop, its app launcher entry, rclone,
and the same user services on X299, X299-SSD, M90aPro, and PortableSSD. Open
**Scramble Desktop** from the app launcher and sign in to browse your cloud files.
The desktop app is installed by the rebuild; no manual download is needed.
Launching it reconnects the local WebDAV backend, restores the cloud views,
initializes empty local sync folders when their credentials are available, and
starts their timers and an immediate sync. Launching it again restores the
same window rather than creating a duplicate.

Nemo has bookmarks for two editable local folders and their read-only cloud
views:

| Folder | Purpose | Cloud destination |
| --- | --- | --- |
| `~/Documents/Scramble Public` | Editable public sync folder | `scramble_drive:PublicSync/Current` |
| `~/Documents/Scramble Sync` | Editable private sync folder | `scramble_private:Current` |
| `~/Scramble Public` | Read-only view of all existing cloud files | `scramble_drive:` |
| `~/Scramble Private` | Read-only decrypted private cloud view | `scramble_private:Current` |

The public folder uses Scramble's normal account encryption. It is not an
anonymous public share. The private folder adds rclone crypt encryption:
the raw `EncryptedSync` folder in Scramble contains encrypted names and files.

M90aPro already has a signed-in Scramble Desktop and an initialized sync.
Its WebDAV service stays on `127.0.0.1:1900`. The other hosts use the
official Scramble CLI to serve WebDAV on their own loopback address. Each
host must log in to the same Scramble account locally.

## Set up another host

1. Boot that host, update its `~/Projects` checkout with `git pull --ff-only`,
   then run `sudo nixos-rebuild switch --flake ~/Projects/NixOS#HOST`, replacing
   `HOST` with `X299`, `X299-SSD`, or `PortableSSD`. This installs Scramble
   Desktop as well as the shared rclone units and helper commands. If you only
   want the desktop app, open it from the app launcher and sign in; the remaining
   steps set up the public and private folder sync.
2. Run `scramble-host-prepare` in a terminal on that host. It installs the
   pinned Scramble CLI, prompts for your Scramble login locally, generates
   separate local WebDAV credentials, and starts the loopback WebDAV service.
   This login is separate from Desktop login. The helper also mounts your
   existing cloud files at Nemo's **Scramble Public Cloud (read-only)** bookmark;
   no private crypt key or local sync initialization is required for that view.
   Run `scramble-sync-init public` to initialize public local sync independently.
   The launcher opens this setup terminal automatically if local WebDAV
   credentials are missing. This is a one-time login on each host, not something
   to repeat after quitting and reopening Scramble.
3. From M90aPro, run `scramble-transfer-crypt SSH_HOST`, replacing `SSH_HOST`
   with a working SSH name or address for the destination. SSH host-key
   verification must already work. This transfers **only** the rclone crypt
   settings. It does not copy the M90aPro WebDAV password or Scramble login.
4. On the destination host, run `scramble-sync-init`. It checks both rclone
   remotes, initializes both local folders, performs their first two-way sync,
   and starts both timers and cloud mounts. Each local folder must be empty
   before its first initialization.
   Alternatively, launch Scramble Desktop again: it imports the transferred
   key and initializes the empty private folder automatically. It never
   generates a new crypt key to replace a missing one or overwrites a nonempty
   local folder during initialization.

Repeat steps 1–4 for each additional host. The hosts do not need to be
online at the same time to exchange files through Scramble Cloud.

On an already initialized host such as M90aPro, run `scramble-sync-init` once
after rebuilding to add the public folder. It leaves the existing private sync
baseline and crypt keys in place.

## Use and verify

Edit files in Nemo's **Scramble Public Sync** and **Scramble Private Sync**
bookmarks. Both folders work offline. Their five-minute timers carry edits and
deletions in both directions. The **Cloud (read-only)** bookmarks show their
cloud copies, with the private copy decrypted by rclone crypt. These bookmarks
appear after rebuilding; the cloud views become mounts after setup completes.
The public cloud bookmark shows the entire existing account, not just the
dedicated `PublicSync/Current` local-sync folder. Existing files outside that
folder are browsable but are not automatically downloaded into public local
sync. Desktop login alone does not start the CLI, create rclone configuration,
or initialize either local sync.
Check the timers with `systemctl --user list-timers 'scramble-*-sync.timer'`,
or run both syncs immediately with
`systemctl --user start scramble-public-sync.service scramble-private-sync.service`.
The AGS bar shows the Scramble icon with a green dot when the connection,
timers, cloud mounts, and last syncs are healthy. Click it to open Scramble
Desktop. Minimize hides the desktop window to its tray icon. Choose
**Open Scramble Desktop** in its tray menu, click the Scramble status icon,
or launch the app again to restore the existing window. The tray's **Quit**
action stops the timers, waits for any active sync to finish, unmounts the
read-only views, stops the CLI backend when used, and shuts down the app.
Right-click either the native tray icon or the Scramble status icon for
**Open Scramble Desktop**, **Open Public Sync Folder**, **Open Private Sync
Folder**, **Browse Cloud Files**, **Sync Now**, **Sync Status**, and **Quit**.
The launcher brings the stopped services back automatically after quitting;
stored logins and crypt keys are retained. A grey dot means Scramble was quit.
Yellow means setup is
pending or a sync is running; red means a service stopped, the last sync failed,
or no sync succeeded in 15 minutes. Hover over it for details, or run
`scramble-sync-status` in a terminal.
The indicator checks local service state; a new network failure appears after
the next sync attempt.

These are user services. They start automatically when you log in; M90aPro's
Scramble Desktop and the cloud mounts need a graphical session. They do not
sync before login. There is no separate crypt daemon: rclone encrypts uploads
and decrypts downloads as each sync or mount request runs.

If two hosts edit the same file before syncing, rclone may preserve both as
conflict copies. The timer uses downloaded hashes because this WebDAV
backend does not provide usable hashes, so a large folder can incur
substantial traffic. Earlier versions removed during a sync are kept in
`~/Documents/.Scramble Sync History` or the encrypted cloud `History` folder.
Public versions are kept in `~/Documents/.Scramble Public History` and
`scramble_drive:PublicSync/History`.

Keep `~/.config/rclone/rclone.conf` private and back it up securely: its
lightly obscured crypt keys are needed to decrypt this folder. No keys are
stored in the flake or Nix store. The local working folder is plaintext
while the host is unlocked.
