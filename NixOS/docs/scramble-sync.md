# One encrypted Scramble Private folder

All four hosts use one real, writable offline folder:

| Local folder | Cloud destination |
| --- | --- |
| `~/Scramble Private` | `scramble_private:Current` |

This is a normal local directory, **not a FUSE mount**. Files remain available
without a network connection or a running Scramble app. `References`,
`trident-optics-attachment`, `Misc`, and the existing private files live inside
this folder. Nemo has one **Scramble Private** bookmark.

For a direct cloud view, `~/Scramble Cloud` is a separate **read-only mount**
shown under Nemo's Devices. It decrypts `scramble_private:Current` using the
original crypt key, so it has the same readable folder layout as
`~/Scramble Private`: `References`, `Misc`, `trident-optics-attachment`, and
the other private folders are at the same relative paths. The cloud view
requires a connection and refreshes directory listings after a short cache
period (15 seconds). Files still awaiting their initial upload appear locally
first; the mount shows only what has reached the cloud.

The Scramble website shows the account's underlying layout, including
`EncryptedSync` and the retained public originals. Those names differ because
the private cloud contents are encrypted. The old `References`, `Misc`, and
`PublicSync` originals remain available there for rollback.

All cloud uploads use the original `scramble_private` rclone-crypt configuration,
whose underlying destination remains `scramble_drive:EncryptedSync`. Filenames
and contents are encrypted in addition to Scramble's account encryption. Local
offline copies are ordinary readable files; rclone crypt does not encrypt the
local filesystem.

## Upgrade existing hosts

Pull and rebuild the shared NixOS configuration, then launch **Scramble Desktop**.
The same configuration applies to X299, X299-SSD, M90aPro, and PortableSSD.
Scramble starts in the tray at graphical login without opening its window.

The first launch starts `scramble-consolidate.service` in the background. It:

1. Validates the existing crypt key by decrypting the private access marker.
   It never generates or replaces a crypt key.
2. Gracefully pauses the old public/private syncs and reference-book timer,
   unmounts both old cloud views, and saves local files and the rclone
   configuration under `~/.local/state/scramble/consolidation`.
3. Moves the old local private, public, and reference folders into
   `~/Scramble Private`, preserving different versions as conflict files rather
   than overwriting them. The old project attachment link is updated too.
4. Imports cloud-only files, including `Misc` and reference books, and copies
   the old public cloud history into `scramble_private:History/LegacyPublic`.
5. Uploads everything into encrypted private storage, checks the decrypted
   cloud contents against every local file, and establishes the new sync
   baseline. Only then is normal two-way sync enabled.

The old public cloud folders are **retained for rollback until every host has
been upgraded**. They are no longer synchronized by an upgraded host. Do not
delete these originals while older hosts can still write to them. The migration
does not delete or purge cloud originals.

Migration checkpoints survive interruptions. A failed transfer retries without
repeating completed local moves. The tray status popup shows the current phase.
The initial encrypted upload can take a long time for a multi-gigabyte library.
Inspect it with:

```sh
scramble-sync-status
journalctl --user -u scramble-consolidate.service -f
```

The migration is complete when
`~/.config/rclone/scramble-private-v2-ready` exists. Different local and cloud
versions are retained with `.from-local-HOST-HASH` or `.from-cloud-HOST-HASH`
in their names. Review these before deleting recovery backups.

## Set up another host

Scramble Desktop and its launcher are installed by the rebuild; no manual
download is needed. Each host signs into the same account locally.

- On X299, X299-SSD, and PortableSSD, run `scramble-host-prepare` to install the
  pinned CLI, sign in, and configure the loopback WebDAV connection.
- M90aPro uses the signed-in Desktop app as its WebDAV backend.
- Transfer the existing private key from an initialized host with
  `scramble-transfer-crypt SSH_HOST`, or securely place the private-only import
  at `~/.config/rclone/scramble-private-import.conf`. The initializer refuses to
  overwrite a different key and removes a successfully consumed import.
- Run `scramble-sync-init`, or relaunch Scramble Desktop. An existing host is
  consolidated safely; a new host downloads the encrypted private contents.

Never copy another host's WebDAV password over your own local connection
configuration. Never create a replacement crypt key for existing cloud data.

## Daily use

Edit working files in `~/Scramble Private`. The single private sync timer runs
every five minutes. Working files use normal two-way sync: edits and deletions
propagate, with replaced/deleted versions backed up locally and in encrypted
cloud history.

The large `References` and `Misc` libraries use non-destructive add-only copying
in both directions, preserving the existing reference-book policy. New files
are copied, but an existing file is not overwritten or deleted. To publish a
revised library document, give it a new filename. Remove unwanted copies from
both sides, or an add-only copy will restore them.

Working-file sync uses downloaded hashes because the WebDAV backend does not
reliably expose modification times or hashes. Library folders are excluded
from that expensive scan, so multi-gigabyte libraries are not downloaded every
five minutes. The migration verifies the entire encrypted folder once before
switching over. Concurrent working-file changes on multiple hosts can still
produce conflict copies; avoid editing the same file on two offline hosts.

Keep the real attachment folder inside `~/Scramble Private` and link the project
path to it. Rclone does not follow symlinks inside the sync folder. Existing
links into the old Scramble folders are redirected during consolidation.
Sioyek also redirects old document paths and updates matching saved history
entries to preserve offline reading and annotations.

Right-click the tray icon for **Open Scramble Desktop**, **Open Scramble Private
Folder**, **Browse Scramble Cloud**, **Sync Now**, **Sync Status**, and **Quit**.
Status opens a notification, not a terminal. The tray always shows a health
badge without a text label: **blue** for active work, **green** for healthy
scheduled idle, **yellow** for setup or a paused migration, **red** for a failure
or lost connection, and **gray** after an intentional Quit. Hover to see the
status and initial upload counter. A stopped transfer between scheduled jobs
is normal.

`scramble-health.service` checks actual transfer PIDs and service states every
five seconds, independently of Scramble Desktop and the bar. It also reads a
small encrypted cloud access marker about every 20 seconds to check the
connection and key. The tooltip and Sync Status popup show the live transfer
PID, live transfer speed, recent rclone transfer statistics, and the last
successful sync. Rclone reports transfer statistics every five seconds; they
describe the current transfer, not the entire migration. A recent completed
transfer's speed is labeled as recent when the next job has not reported yet.
Samples older than 15 seconds are hidden, and scheduled idle shows 0 B/s.

Desktop notifications announce monitoring startup, persistent failures, and
recovery. A ten-second delay prevents brief service transitions from producing
false failure alerts. Intentional Quit is reported as stopped. If the Desktop
tray item disappears, the bar retains a status icon; left-click relaunches
Scramble and right-click opens the status notification. A stale monitor cache
is shown as an error instead of appearing healthy. Inspect the monitor with
`journalctl --user -u scramble-health.service`.

Quitting safely pauses a migration, waits for an ordinary active sync,
unmounts the cloud view, stops the timer/backend, and removes the icon.
Relaunching reconnects and resumes the same setup automatically. The next
graphical login starts it again.

Normal local history is under `~/.local/state/scramble/history`; migration
backups and old local histories are under
`~/.local/state/scramble/consolidation`. These hidden recovery directories are
not additional working folders or cloud mounts. The cloud mount does not create
another sync job or a second offline working copy.

## Back up the key

Keep `~/.config/rclone/rclone.conf` private (mode `600`) and back it up to an
encrypted external backup or password vault. Its `[scramble_private]` section
contains the original crypt password and salt needed to recover the cloud
data. Losing them makes the encrypted files unrecoverable. The migration's
configuration backup is local recovery protection, not a substitute for an
independent secure backup. Do not commit credentials or keys to Git, or place
them in a normal cloud sync folder.
