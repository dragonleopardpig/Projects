# crucial-btrfs-migrate: move CRUCIAL-SSD from ext4 to the impermanent btrfs
# layout inside the SAME LUKS container.  Packaged by
# packages/crucial-btrfs-migrate.nix (installed on PortableSSD); the full
# procedure is hosts/Crucial-SSD/MIGRATE.md.
#
#   prepare        on CRUCIAL-SSD itself (ext4, as thinky): build the btrfs
#                  system + list the persisted paths into ~/.local/state
#   check          on PortableSSD: identify the disk, show what is done
#   stage          exact image of today's root onto the (empty) CRUCIALDATA
#                  partition, reformatted ext4 "CRUCIAL-STAGE"   [rollback point]
#   format         btrfs + subvolumes inside the existing LUKS     [ERASES ROOT]
#   copy           /nix, /home, persisted state, password hashes -> subvolumes
#   install        set the system profile + install GRUB on Crucial's ESP
#   rollback       write the image back (ext4 again), any time before release
#   release-stage  after good boots: CRUCIALDATA back to an empty FAT32
#   umount         undo mounts / close LUKS after an interrupted phase
#
# Options: --dry-run (print destructive commands instead of running them).
# Environment overrides (the VM rehearsal uses them): CRUCIAL_LUKS_UUID,
# CRUCIAL_ESP_UUID, CRUCIAL_USER, CRUCIAL_MNT, CRUCIAL_KEY_FILE, CRUCIAL_YES=1,
# CRUCIAL_EXCLUDES, CRUCIAL_REPO.

# Also set by writeShellApplication; repeated for `bash crucial-btrfs-migrate.sh`.
set -euo pipefail

LUKS_UUID=${CRUCIAL_LUKS_UUID:-77595ddf-4ac1-4521-a712-25f2dfaa02c3}
ESP_UUID=${CRUCIAL_ESP_UUID:-42F5-D6BF}
DATA_LABEL=CRUCIALDATA
STAGE_LABEL=CRUCIAL-STAGE
TARGET_USER=${CRUCIAL_USER:-thinky}
MNT=${CRUCIAL_MNT:-/mnt/crucial}
MAPPER=crucial-root
REPO=${CRUCIAL_REPO:-/home/thinky/Projects/NixOS}
# Rebuilt on first use anyway; relative to /home.
EXCLUDES=${CRUCIAL_EXCLUDES:-"thinky/Projects/strata/target thinky/Projects/spacedrive/target"}
SUBVOLS="@root @nix @persist @home @swap"
STATE_REL=".local/state/crucial-migration"
IMAGE_NAME=crucial-root-ext4.img

usage() {
  cat <<'EOF'
usage: crucial-btrfs-migrate [--dry-run] PHASE      (hosts/Crucial-SSD/MIGRATE.md)
  prepare        on CRUCIAL-SSD (ext4), as thinky: build the btrfs system
  check          on PortableSSD: identify the disk, show which phases ran
  stage          image today's root onto CRUCIALDATA (reformatted ext4)
  format         btrfs subvolumes inside the existing LUKS   [ERASES ROOT]
  copy           /nix, /home, persisted state, passwords -> subvolumes
  install        system profile + GRUB on Crucial's ESP
  rollback       write the ext4 image back
  release-stage  CRUCIALDATA back to an empty FAT32 (after good boots)
  umount         undo mounts / close LUKS after an interrupted phase
EOF
}

DRY=0
PHASE=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    -h | --help) usage; exit 0 ;;
    -*) echo "unknown option $arg" >&2; exit 2 ;;
    *) PHASE=$arg ;;
  esac
done

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Destructive or state-changing commands go through run(); read-only
# inspection runs directly, so --dry-run still checks the disk identity.
run() {
  if [ "$DRY" = 1 ]; then
    printf '[dry-run]'; printf ' %q' "$@"; printf '\n'
  else
    "$@"
  fi
}

confirm() {
  local word=$1 what=$2 reply
  [ "${CRUCIAL_YES:-0}" = 1 ] && return 0
  [ "$DRY" = 1 ] && return 0
  printf '\n%s\nType %s to continue: ' "$what" "$word"
  read -r reply
  [ "$reply" = "$word" ] || die "not confirmed; nothing changed"
}

MOUNTS=()
OPENED=0
cleanup() {
  local i
  for ((i = ${#MOUNTS[@]} - 1; i >= 0; i--)); do
    umount "${MOUNTS[$i]}" 2>/dev/null || umount -l "${MOUNTS[$i]}" 2>/dev/null || true
  done
  MOUNTS=()
  if [ "$OPENED" = 1 ]; then
    cryptsetup close "$MAPPER" 2>/dev/null || true
    OPENED=0
  fi
}
trap cleanup EXIT

mnt() { # mnt <dir> <mount args...>      (skipped by --dry-run)
  local dir=$1; shift
  run mkdir -p "$dir"
  run mount "$@" "$dir"
  MOUNTS+=("$dir")
}

mnt_real() { # mnt_real <dir> <mount args...>  (also under --dry-run: use -o ro)
  local dir=$1; shift
  mkdir -p "$dir"
  mount "$@" "$dir"
  MOUNTS+=("$dir")
}

# A desktop on PortableSSD may have auto-mounted a partition; mkfs and
# cryptsetup refuse busy devices, so let go of those mounts first.
release_mounts() { # release_mounts <device>
  local t
  for t in $(findmnt -rno TARGET -S "$1" 2>/dev/null | sort -r); do
    say "Unmounting $1 from $t (auto-mounted)"
    run umount "$t"
  done
}

need_root() { [ "$(id -u)" = 0 ] || die "run as root (sudo $0 $PHASE)"; }

# What an empty FAT partition still holds after Windows and a desktop saw it:
# the indexer's state, an empty Recycle Bin, empty trash folders.  Anything
# put in the bin or the trash is not a placeholder.
placeholder() { # placeholder <find %y type> <path relative to the partition>
  local kind=$1 rel=$2 top=${2%%/*} rest
  rest=${rel#"$top"}
  rest=${rest#/}
  case "$top" in
    'System Volume Information') return 0 ;;
    "\$RECYCLE.BIN")
      case "$rest" in
        '') [ "$kind" = d ] ;;
        desktop.ini | S-*/desktop.ini) [ "$kind" = f ] ;;
        S-*) [ "$kind" = d ] && [[ $rest != */* ]] ;;
        *) return 1 ;;
      esac ;;
    .Trash-*)
      case "$rest" in
        '' | info | files | expunged) [ "$kind" = d ] ;;
        *) return 1 ;;
      esac ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------- devices --

LUKS_PART="" DISK="" ESP_PART="" DATA_PART="" DATA_STATE=""

find_devices() {
  LUKS_PART=$(readlink -f "/dev/disk/by-uuid/$LUKS_UUID" 2>/dev/null || true)
  [ -b "$LUKS_PART" ] || die "LUKS partition UUID $LUKS_UUID not found: is the Crucial disk plugged in?"
  cryptsetup isLuks "$LUKS_PART" || die "$LUKS_PART is not LUKS"
  DISK=/dev/$(lsblk -no PKNAME "$LUKS_PART" | head -1)
  [ -b "$DISK" ] || die "cannot find the disk holding $LUKS_PART"

  ESP_PART=$(readlink -f "/dev/disk/by-uuid/$ESP_UUID" 2>/dev/null || true)
  [ -b "$ESP_PART" ] || die "ESP UUID $ESP_UUID not found"
  [ "/dev/$(lsblk -no PKNAME "$ESP_PART" | head -1)" = "$DISK" ] || die "ESP $ESP_PART is not on $DISK"

  local name label
  while read -r name label; do
    case "$label" in
      "$DATA_LABEL") DATA_PART=$name DATA_STATE=data ;;
      "$STAGE_LABEL") DATA_PART=$name DATA_STATE=stage ;;
    esac
  done < <(lsblk -nrpo NAME,LABEL "$DISK" | awk 'NF == 2')
  [ -n "$DATA_PART" ] || die "no partition labelled $DATA_LABEL or $STAGE_LABEL on $DISK"

  # Never touch the disk we are running from.
  local src
  src=$(findmnt -no SOURCE / | sed 's/\[.*//')
  if lsblk -nrps -o NAME "$src" 2>/dev/null | grep -qx "$LUKS_PART"; then
    die "the running system boots from $LUKS_PART; boot PortableSSD for this phase"
  fi
}

open_luks() { # open_luks [--readonly]     (real even under --dry-run: not destructive)
  local other
  other=$(lsblk -nrpo NAME,TYPE "$LUKS_PART" | awk '$2 == "crypt" { print $1 }' | grep -vx "/dev/mapper/$MAPPER" || true)
  [ -z "$other" ] || die "$LUKS_PART is already unlocked as $other (file manager?): close it with 'cryptsetup close ${other##*/}'"
  if [ -e "/dev/mapper/$MAPPER" ]; then
    local backing
    backing=$(lsblk -nrps -o NAME "/dev/mapper/$MAPPER" | sed -n 2p)
    [ "$backing" = "$LUKS_PART" ] || die "/dev/mapper/$MAPPER exists but is not $LUKS_PART"
    if [ "${1:-}" != --readonly ] && cryptsetup status "$MAPPER" | grep -q 'mode:.*read-only'; then
      die "/dev/mapper/$MAPPER is open read-only from an earlier run: crucial-btrfs-migrate umount"
    fi
    return 0
  fi
  local args=(open "$@" "$LUKS_PART" "$MAPPER")
  [ -n "${CRUCIAL_KEY_FILE:-}" ] && args+=(--key-file "$CRUCIAL_KEY_FILE")
  say "Unlocking $LUKS_PART as /dev/mapper/$MAPPER"
  cryptsetup "${args[@]}"
  OPENED=1
}

inner_fstype() { blkid -p -s TYPE -o value "/dev/mapper/$MAPPER" 2>/dev/null || true; }

STAGE=$MNT/stage
mount_stage() {
  [ "$DATA_STATE" = stage ] || die "phase 'stage' has not run ($DATA_PART is still $DATA_LABEL)"
  release_mounts "$DATA_PART"
  if [ "$DRY" = 1 ]; then mnt_real "$STAGE" -o ro "$DATA_PART"; else mnt_real "$STAGE" "$DATA_PART"; fi
  [ -e "$STAGE/crucial-migration/stage.done" ] || die "staging image incomplete; rerun 'stage'"
}
mark() { run touch "$STAGE/crucial-migration/$1.done"; }
done_p() { [ -e "$STAGE/crucial-migration/$1.done" ]; }

NEW=$MNT/new
mount_new() { # mount_new [--with-boot]
  local dev=/dev/mapper/$MAPPER opts=compress=zstd,noatime
  mnt "$NEW" -t btrfs -o "subvol=@root,$opts" "$dev"
  mnt "$NEW/nix" -t btrfs -o "subvol=@nix,$opts" "$dev"
  mnt "$NEW/persist" -t btrfs -o "subvol=@persist,$opts" "$dev"
  mnt "$NEW/home" -t btrfs -o "subvol=@home,$opts" "$dev"
  if [ "${1:-}" = --with-boot ]; then
    mnt "$NEW/boot" -o fmask=0077,dmask=0077 "$ESP_PART"
  fi
}

# ----------------------------------------------------------------- phases --

phase_prepare() {
  [ "$(id -u)" != 0 ] || die "run 'prepare' as $TARGET_USER, not root"
  [ "$(findmnt -no FSTYPE /)" = ext4 ] || die "'prepare' runs on CRUCIAL-SSD while it is still ext4"
  local state=$HOME/$STATE_REL
  run mkdir -p "$state"
  say "Building nixosConfigurations.CRUCIAL-SSD-btrfs (kept alive by $state/system)"
  run nix build --impure "path:$REPO#nixosConfigurations.CRUCIAL-SSD-btrfs.config.system.build.toplevel" \
    --out-link "$state/system"
  say "Listing the paths the btrfs system persists"
  local list
  # shellcheck disable=SC2016  # Nix code, not shell
  list=$(nix eval --impure --raw \
    "path:$REPO#nixosConfigurations.CRUCIAL-SSD-btrfs.config.environment.persistence" \
    --apply 'p: let x = p."/persist"; in builtins.concatStringsSep "\n"
      (map (d: "dir ${d.dirPath}") x.directories ++ map (f: "file ${f.filePath}") x.files) + "\n"')
  # $(...) strips the final newline; without it `read` would drop the last entry.
  if [ "$DRY" = 1 ]; then printf '%s\n' "$list"; else printf '%s\n' "$list" > "$state/persist.txt"; fi
  say "Ready: $(readlink -f "$state/system" 2>/dev/null || echo '(dry run)')"
  df -h /
  cat <<EOF

Before shutting down (MIGRATE.md, step B0):
  * stop gates; tell the Kraken / trident sessions the machine goes down
  * push every repo; run sync-projects to the second SSD
  * back up ~/.ssh ~/.gnupg "~/Scramble Private" ~/.claude to the second SSD
  * update PortableSSD so it has this tool:  ~/Projects/NixOS/rebuild.sh boot PortableSSD
Then shut down, boot PortableSSD with the Crucial disk attached, and run:
  sudo crucial-btrfs-migrate check
EOF
}

phase_check() {
  need_root
  find_devices
  say "Crucial disk: $DISK ($(lsblk -dno MODEL,SIZE "$DISK" | xargs))"
  lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS "$DISK"
  echo "  LUKS root : $LUKS_PART"
  echo "  ESP       : $ESP_PART"
  echo "  data      : $DATA_PART ($DATA_STATE)"
  open_luks --readonly
  echo "  inside    : $(inner_fstype)"
  if [ "$DATA_STATE" = stage ]; then
    mnt_real "$STAGE" -o ro "$DATA_PART"
    local p
    for p in stage format copy install; do
      if done_p "$p"; then echo "  phase $p : done"; else echo "  phase $p : -"; fi
    done
  fi
}

phase_stage() {
  need_root
  find_devices
  [ "$DATA_STATE" = data ] || die "$DATA_PART is already $STAGE_LABEL; 'stage' ran before (see 'check')"
  open_luks --readonly
  [ "$(inner_fstype)" = ext4 ] || die "expected ext4 inside LUKS, found '$(inner_fstype)'"

  say "Checking the data partition $DATA_PART is empty"
  local probe=$MNT/data-probe entries
  mnt_real "$probe" -o ro "$DATA_PART"
  entries=$(find "$probe" -mindepth 1 -maxdepth 3 -printf '%y %P\n' 2>/dev/null |
    while read -r kind rel; do placeholder "$kind" "$rel" || echo "$rel"; done | head -20 || true)
  umount "$probe"
  unset 'MOUNTS[${#MOUNTS[@]}-1]'
  [ -z "$entries" ] || die "$DATA_PART ($DATA_LABEL) is not empty; move these first:
$entries"
  release_mounts "$DATA_PART"

  say "Checking the ext4 root (read-only)"
  e2fsck -fn "/dev/mapper/$MAPPER" || die "e2fsck found problems: boot CRUCIAL-SSD, shut down cleanly, retry"

  local bs blocks free used part_bytes
  bs=$(dumpe2fs -h "/dev/mapper/$MAPPER" 2>/dev/null | awk -F: '/^Block size/ {gsub(/ /,"",$2); print $2}')
  blocks=$(dumpe2fs -h "/dev/mapper/$MAPPER" 2>/dev/null | awk -F: '/^Block count/ {gsub(/ /,"",$2); print $2}')
  free=$(dumpe2fs -h "/dev/mapper/$MAPPER" 2>/dev/null | awk -F: '/^Free blocks/ {gsub(/ /,"",$2); print $2}')
  used=$(( (blocks - free) * bs ))
  part_bytes=$(blockdev --getsize64 "$DATA_PART")
  echo "  root uses $(( used / 1073741824 )) GiB; staging partition holds $(( part_bytes / 1073741824 )) GiB"
  [ $(( used + used / 20 + 2147483648 )) -lt "$part_bytes" ] || die "staging partition too small for the image"

  confirm STAGE "Reformat $DATA_PART ($DATA_LABEL, empty) as ext4 '$STAGE_LABEL' and image the root onto it."
  run mkfs.ext4 -q -F -m 0 -L "$STAGE_LABEL" "$DATA_PART"
  udevadm settle || true
  mnt "$STAGE" "$DATA_PART"
  run mkdir -p "$STAGE/crucial-migration"
  run cryptsetup luksHeaderBackup "$LUKS_PART" --header-backup-file "$STAGE/crucial-migration/luks-header.img"
  say "Imaging used blocks of /dev/mapper/$MAPPER (exact copy, sparse)"
  run e2image -ra -p "/dev/mapper/$MAPPER" "$STAGE/$IMAGE_NAME"
  say "Verifying the image"
  run e2fsck -fn "$STAGE/$IMAGE_NAME"
  run sync
  mark stage
  say "Rollback point ready: $STAGE/$IMAGE_NAME.  Next: sudo crucial-btrfs-migrate format"
}

phase_format() {
  need_root
  find_devices
  mount_stage
  confirm FORMAT "ERASE the ext4 root inside $LUKS_PART and create btrfs subvolumes ($SUBVOLS).
The verified image on $STAGE_LABEL is the only copy of it afterwards."
  open_luks
  run wipefs -a "/dev/mapper/$MAPPER"
  run mkfs.btrfs -q -f -L nixos "/dev/mapper/$MAPPER"
  local top=$MNT/top s
  mnt "$top" -t btrfs -o subvol=/ "/dev/mapper/$MAPPER"
  for s in $SUBVOLS; do run btrfs subvolume create "$top/$s"; done
  mark format
  say "Next: sudo crucial-btrfs-migrate copy"
}

phase_copy() {
  need_root
  find_devices
  mount_stage
  [ "$DRY" = 1 ] || done_p format || die "run 'format' first"
  open_luks
  [ "$DRY" = 1 ] || [ "$(inner_fstype)" = btrfs ] || die "expected btrfs inside LUKS"
  local old=$MNT/old
  mnt_real "$old" -o ro,loop,noload "$STAGE/$IMAGE_NAME"
  mount_new

  local state=$old/home/$TARGET_USER/$STATE_REL
  [ -e "$state/persist.txt" ] || die "$state/persist.txt missing: run 'prepare' on CRUCIAL-SSD first"
  local system
  system=$(readlink "$state/system" || true)
  [ -n "$system" ] && [ -e "$old$system" ] || die "prebuilt system missing ($state/system): rerun 'prepare'"

  local rs=(rsync -aHAXS --numeric-ids --info=progress2)
  say "Copying /nix (store, database, profiles)"
  run "${rs[@]}" "$old/nix/" "$NEW/nix/"

  say "Copying /home"
  local ex=() e
  for e in $EXCLUDES; do ex+=("--exclude=/$e"); done
  run "${rs[@]}" "${ex[@]}" "$old/home/" "$NEW/home/"

  say "Copying persisted system state"
  local kind path
  while read -r kind path; do
    [ -n "$path" ] || continue
    if [ ! -e "$old$path" ] && [ ! -L "$old$path" ]; then
      echo "  (absent, will be created on boot) $path"
      continue
    fi
    run mkdir -p "$NEW/persist$(dirname "$path")"
    if [ "$kind" = dir ]; then
      run rsync -aHAXS --numeric-ids "$old$path/" "$NEW/persist$path/"
    else
      run rsync -aHAXS --numeric-ids "$old$path" "$NEW/persist$path"
    fi
    echo "  $path"
  done < <(cat "$state/persist.txt"; echo)

  say "Carrying the current password hashes over (mutableUsers = false reads them from /persist)"
  run install -d -m 0700 "$NEW/persist/passwords"
  local u hash
  for u in "$TARGET_USER" root; do
    hash=$(awk -F: -v u="$u" '$1 == u { print $2 }' "$old/etc/shadow")
    if [ "$u" = "$TARGET_USER" ]; then
      case "$hash" in
        "" | "!"* | "*"*) die "$TARGET_USER has no usable password hash in /etc/shadow: login would be impossible" ;;
      esac
    fi
    [ -n "$hash" ] || hash='!'
    if [ "$DRY" = 1 ]; then
      echo "[dry-run] write hash of $u to $NEW/persist/passwords/$u"
    else
      (umask 077; printf '%s\n' "$hash" > "$NEW/persist/passwords/$u")
    fi
  done

  run sync
  mark copy
  say "Copied.  New layout: $(df -h --output=used "$NEW" | tail -1 | xargs) used.  Next: sudo crucial-btrfs-migrate install"
}

phase_install() {
  need_root
  find_devices
  mount_stage
  [ "$DRY" = 1 ] || done_p copy || die "run 'copy' first"
  open_luks
  release_mounts "$ESP_PART"
  mount_new --with-boot
  # Activation inside the chroot should see the persisted uid/gid map, as the
  # real boot will (impermanence bind-mounts it in the initrd).
  if [ -d "$NEW/persist/var/lib/nixos" ] || [ "$DRY" = 1 ]; then
    mnt "$NEW/var/lib/nixos" --bind "$NEW/persist/var/lib/nixos"
  fi
  local system
  system=$(readlink "$NEW/home/$TARGET_USER/$STATE_REL/system" || true)
  [ -n "$system" ] && [ -e "$NEW$system" ] || [ "$DRY" = 1 ] || die "prebuilt system missing in the new store"
  say "Setting the system profile to $system"
  run nix-env --store "$NEW" -p "$NEW/nix/var/nix/profiles/system" --set "$system"
  run mkdir -p "$NEW/etc"
  run touch "$NEW/etc/NIXOS"
  run ln -sfn /proc/mounts "$NEW/etc/mtab"
  say "Installing the boot loader onto $ESP_PART"
  run nixos-enter --root "$NEW" -c \
    "NIXOS_INSTALL_BOOTLOADER=1 /nix/var/nix/profiles/system/bin/switch-to-configuration boot"
  run sync
  mark install
  say "Installed.  Shut down, unplug PortableSSD, boot CRUCIAL-SSD and follow MIGRATE.md step B5."
}

phase_rollback() {
  need_root
  find_devices
  mount_stage
  confirm ROLLBACK "Overwrite everything inside $LUKS_PART with the ext4 image from $STAGE_LABEL."
  open_luks
  say "Writing the image back (whole filesystem)"
  run dd if="$STAGE/$IMAGE_NAME" of="/dev/mapper/$MAPPER" bs=64M conv=fsync status=progress
  run e2fsck -fn "/dev/mapper/$MAPPER"
  run rm -f "$STAGE"/crucial-migration/{format,copy,install}.done
  say "ext4 root restored.  Boot CRUCIAL-SSD, pick the PREVIOUS generation in the GRUB menu,"
  say "then run: sudo nixos-rebuild boot --flake ~/Projects/NixOS#CRUCIAL-SSD --impure"
}

phase_release_stage() {
  need_root
  find_devices
  [ "$DATA_STATE" = stage ] || die "$DATA_PART is not $STAGE_LABEL; nothing to release"
  open_luks --readonly
  [ "$(inner_fstype)" = btrfs ] || die "the root is not btrfs yet: keep the image"
  confirm RELEASE "Delete the rollback image and make $DATA_PART an empty FAT32 '$DATA_LABEL' again."
  run wipefs -a "$DATA_PART"
  run mkfs.vfat -F 32 -n "$DATA_LABEL" "$DATA_PART"
  say "$DATA_PART is $DATA_LABEL again (partition type unchanged)."
}

phase_umount() {
  need_root
  local m
  for m in $(findmnt -rno TARGET | grep "^$MNT" | sort -r); do umount "$m" || umount -l "$m"; done
  [ -e "/dev/mapper/$MAPPER" ] && cryptsetup close "$MAPPER"
  say "Unmounted $MNT and closed $MAPPER."
}

case "$PHASE" in
  prepare) phase_prepare ;;
  check) phase_check ;;
  stage) phase_stage ;;
  format) phase_format ;;
  copy) phase_copy ;;
  install) phase_install ;;
  rollback) phase_rollback ;;
  release-stage) phase_release_stage ;;
  umount) phase_umount ;;
  *) die "usage: crucial-btrfs-migrate [--dry-run] prepare|check|stage|format|copy|install|rollback|release-stage|umount" ;;
esac
