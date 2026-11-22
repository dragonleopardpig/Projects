# x299-btrfs-migrate: move X299-SSD from ext4 to the impermanent btrfs layout and to
# CRUCIAL-SSD's partition style, run from another machine (M90aPro) with the X299 disk
# plugged in.  Packaged by packages/x299-btrfs-migrate.nix; the procedure is
# hosts/X299-SSD/MIGRATE.md.
#
#   before                                   after
#   p1 BIOS-BOOT   8 MiB (unused)            p1 EFI       10 GiB  (same FAT volume id)
#   p2 EFI        98 GiB (92 MB used)        p2 LUKS2     up to DATA (same UUID, same
#   p3 LUKS2 -> ext4 root                                 passphrase) -> btrfs subvolumes
#   p4 DATA (FAT)                            p3 DATA            } renumbered only: same
#   p5 Virtual Windows (ext4)                p4 Virtual Windows } sectors, never written
#
#   prepare        build the btrfs system + list what it persists (into the stage dir)
#   check          identify the disk, show its layout and which phases ran
#   stage          rollback point on ANOTHER disk: GPT + first sectors, a tar of the ESP,
#                  and the raw (still encrypted) LUKS partition, checksummed
#   format         new partition table, new ESP and LUKS, btrfs subvolumes  [ERASES ROOT]
#   copy           system closure + user profiles, /home without dev artifacts and
#                  ~/.cache, persisted state, password hashes -> the new subvolumes
#   install        system profile + GRUB on X299's ESP (removable path, no NVRAM)
#   rollback       old partition table, ESP and encrypted root back, any time before release
#   release-stage  after X299 booted the new layout: delete the stage dir
#   umount         undo mounts / close LUKS after an interrupted phase
#
# The stage dir must be on a disk other than X299's.  Nothing decrypted is written there:
# the LUKS partition is imaged raw, and copy reads it through dm-crypt.
#
# Options: --dry-run (print state-changing commands instead of running them).
# Environment (the VM rehearsal sets some): X299_LUKS_UUID, X299_ESP_UUID, X299_USER,
# X299_MNT, X299_STAGE, X299_KEY_FILE (the passphrase, no newline, on tmpfs), X299_YES=1,
# X299_REPO, X299_ESP_MIB, X299_LUKS_FORMAT_ARGS, X299_SWEEP, X299_SWEEP_EXCLUDES.

set -euo pipefail

LUKS_UUID=${X299_LUKS_UUID:-d9622547-f79a-4640-8036-b478f59bf3fd}
ESP_UUID=${X299_ESP_UUID:-0C04-2087}
TARGET_USER=${X299_USER:-thinky}
MNT=${X299_MNT:-/mnt/x299}
STAGE=${X299_STAGE:-/mnt/backup/x299-migration}
KEY=${X299_KEY_FILE:-/dev/shm/x299.key}
REPO=${X299_REPO:-/home/thinky/Projects/NixOS}
ESP_MIB=${X299_ESP_MIB:-10240}
# shellcheck disable=SC2206  # word splitting wanted: extra luksFormat options
LUKS_FORMAT_ARGS=(${X299_LUKS_FORMAT_ARGS:-})
SWEEP=${X299_SWEEP:-$REPO/modules/impermanence-clean-dev.py}
SWEEP_EXCLUDES=${X299_SWEEP_EXCLUDES:-$REPO/scripts/sweep-excludes.py}
SUBVOLS="@root @nix @persist @home @swap"
OLD_MAP=x299-old
NEW_MAP=x299-new
IMAGE=$STAGE/x299-cryptroot.img
BIOS_BOOT_TYPE=21686148-6449-6e6f-744e-656564454649
ESP_TYPE=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
export PYTHONIOENCODING=utf-8:surrogateescape

usage() {
  cat <<'EOF'
usage: x299-btrfs-migrate [--dry-run] PHASE      (hosts/X299-SSD/MIGRATE.md)
  prepare        build the btrfs system, list what it persists
  check          identify the disk, show its layout and which phases ran
  stage          GPT, ESP and the raw encrypted root onto the stage dir
  format         CRUCIAL-style partitions, new LUKS + btrfs   [ERASES ROOT]
  copy           system, user profiles, /home (no dev artifacts), state
  install        system profile + GRUB on X299's ESP
  rollback       the old partitions, ESP and root back
  release-stage  delete the stage dir (after X299 booted the new layout)
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

# State-changing commands go through run(); read-only inspection runs directly, so
# --dry-run still checks the disk identity.
run() {
  if [ "$DRY" = 1 ]; then
    printf '[dry-run]'; printf ' %q' "$@"; printf '\n'
  else
    "$@"
  fi
}

confirm() {
  local word=$1 what=$2 reply
  [ "${X299_YES:-0}" = 1 ] && return 0
  [ "$DRY" = 1 ] && return 0
  printf '\n%s\nType %s to continue: ' "$what" "$word"
  read -r reply
  [ "$reply" = "$word" ] || die "not confirmed; nothing changed"
}

MOUNTS=()
MAPS=()
TMPFILES=()
cleanup() {
  local i
  for ((i = ${#MOUNTS[@]} - 1; i >= 0; i--)); do
    umount "${MOUNTS[$i]}" 2>/dev/null || umount -l "${MOUNTS[$i]}" 2>/dev/null || true
  done
  MOUNTS=()
  local maps=("${MAPS[@]}")
  for ((i = ${#maps[@]} - 1; i >= 0; i--)); do
    cryptsetup close "${maps[$i]}" 2>/dev/null || true
  done
  MAPS=()
  [ ${#TMPFILES[@]} = 0 ] || rm -f "${TMPFILES[@]}"
}
trap cleanup EXIT

mnt() { # mnt <dir> <mount args...>      (skipped by --dry-run)
  local dir=$1; shift
  run mkdir -p "$dir"
  run mount "$@" "$dir"
  [ "$DRY" = 1 ] || MOUNTS+=("$dir")
}

mnt_real() { # mnt_real <dir> <mount args...>  (also under --dry-run: use -o ro)
  local dir=$1; shift
  mkdir -p "$dir"
  mount "$@" "$dir"
  MOUNTS+=("$dir")
}

unmnt_last() {
  umount "${MOUNTS[${#MOUNTS[@]} - 1]}"
  unset 'MOUNTS[${#MOUNTS[@]}-1]'
}

# A desktop may have auto-mounted a partition; mkfs, cryptsetup and a partition-table
# re-read refuse busy devices, so let go of those mounts first.
release_mounts() { # release_mounts <device>
  local t
  for t in $(findmnt -rno TARGET -S "$1" 2>/dev/null | sort -r); do
    say "Unmounting $1 from $(printf '%b' "$t")"
    run umount "$(printf '%b' "$t")"
  done
}

need_root() { [ "$(id -u)" = 0 ] || die "run as root (sudo x299-btrfs-migrate $PHASE)"; }

need_key() {
  [ -f "$KEY" ] || die "no passphrase file $KEY: type it into RAM first (MIGRATE.md):
  read -rs p && printf %s \"\$p\" | sudo install -m 600 /dev/stdin $KEY && unset p"
  case "$(findmnt -no FSTYPE -T "$KEY")" in
    tmpfs | ramfs) ;;
    *) die "$KEY is not on tmpfs: the passphrase must stay in RAM" ;;
  esac
}

# Clients like udiskie mount (and keep busy) every partition that shows up while the
# table is rewritten.
no_automount() {
  if pgrep -f 'bin/\.?udiskie' > /dev/null; then
    die "udiskie is running and would grab the partitions: systemctl --user stop udiskie (start it again after)"
  fi
}

# One line per partition: device number start-sector bytes type-guid partuuid fs-uuid|-
save_partitions() {
  local p u
  for p in $(lsblk -nrpo NAME,TYPE "$DISK" | awk '$2 == "part" { print $1 }'); do
    u=$(lsblk -ndo UUID "$p" | tr -d ' ')
    printf '%s %s %s %s %s %s %s\n' "$p" "$(partn "$p")" "$(lsblk -ndo START "$p" | tr -d ' ')" \
      "$(blockdev --getsize64 "$p")" "$(parttype "$p")" "$(lsblk -ndo PARTUUID "$p" | tr -d ' ')" "${u:--}"
  done
}

# ---------------------------------------------------------------- devices --

DISK="" LAYOUT="" LUKS_PART="" ESP_PART=""
# part_of <disk> <number>: the device of partition <number>, if any.
part_of() {
  lsblk -nrpo NAME,TYPE,PARTN "$1" | awk -v n="$2" '$2 == "part" && $3 == n { print $1 }'
}
partn() { lsblk -ndo PARTN "$1" | tr -d ' '; }
parttype() { lsblk -ndo PARTTYPE "$1" | tr -d ' ' | tr 'A-F' 'a-f'; }

# Never touch the disk this machine runs from.
not_running_disk() {
  local src
  src=$(findmnt -no SOURCE / | sed 's/\[.*//')
  if lsblk -nrps -o NAME "$src" 2>/dev/null | grep -qx "$DISK"; then
    die "the running system is on $DISK; run this from another machine"
  fi
}

find_devices() {
  local found
  # Partitions only: the staged image carries the same LUKS UUID once it is attached.
  found=$(lsblk -nrpo NAME,TYPE,UUID | awk -v u="$LUKS_UUID" '$2 == "part" && $3 == u { print $1 }')
  if [ -z "$found" ] && [ -s "$STAGE/disk" ]; then
    # Between a half-run 'format' and 'rollback' the LUKS header may be gone.
    DISK=$(readlink -f "$(cat "$STAGE/disk")")
    [ -b "$DISK" ] || die "LUKS UUID $LUKS_UUID not found and the staged disk $(cat "$STAGE/disk") is not plugged in"
    not_running_disk
    LAYOUT=broken
    return 0
  fi
  [ -n "$found" ] || die "LUKS partition UUID $LUKS_UUID not found: is the X299 disk plugged in?"
  [ "$(printf '%s\n' "$found" | wc -l)" = 1 ] || die "more than one partition has LUKS UUID $LUKS_UUID: $found"
  LUKS_PART=$found
  cryptsetup isLuks "$LUKS_PART" || die "$LUKS_PART is not LUKS"
  DISK=/dev/$(lsblk -no PKNAME "$LUKS_PART" | head -1)
  [ -b "$DISK" ] || die "cannot find the disk holding $LUKS_PART"

  not_running_disk

  ESP_PART=$(lsblk -nrpo NAME,TYPE,UUID "$DISK" | awk -v u="$ESP_UUID" '$2 == "part" && $3 == u { print $1 }')
  case "$(partn "$LUKS_PART")" in
    3)
      [ "$(parttype "$(part_of "$DISK" 1)")" = "$BIOS_BOOT_TYPE" ] || die "partition 1 of $DISK is not BIOS boot"
      [ -n "$ESP_PART" ] && [ "$(partn "$ESP_PART")" = 2 ] || die "ESP $ESP_UUID is not partition 2 of $DISK"
      LAYOUT=old ;;
    2)
      ESP_PART=$(part_of "$DISK" 1)
      [ "$(parttype "$ESP_PART")" = "$ESP_TYPE" ] || die "partition 1 of $DISK is not an ESP"
      LAYOUT=new ;;
    *) die "LUKS is partition $(partn "$LUKS_PART") of $DISK: neither the old nor the new layout" ;;
  esac
}

# The stage dir: on a mounted filesystem of another disk.
check_stage_disk() {
  local base=$STAGE src target
  while [ ! -e "$base" ]; do base=$(dirname "$base"); done
  # An automount point lists the autofs entry and the filesystem on it: take the latter.
  read -r target src < <(findmnt -nro TARGET,SOURCE,FSTYPE -T "$base" | awk '$3 != "autofs" { t = $1; s = $2 } END { print t, s }')
  src=${src%%\[*}
  [ -b "$src" ] || die "cannot tell which disk holds $STAGE (source '$src')"
  if lsblk -nrps -o NAME "$src" 2>/dev/null | grep -qx "$DISK"; then
    die "the stage dir $STAGE is on the X299 disk itself"
  fi
  [ "$target" != / ] || die "$STAGE is not on a mounted data disk (Linux-Data at /mnt/backup?)"
}

mark() { run touch "$STAGE/$1.done"; }
done_p() { [ -e "$STAGE/$1.done" ]; }

open_map() { # open_map <device-or-file> <name> [--readonly]
  local dev=$1 name=$2; shift 2
  if [ -e "/dev/mapper/$name" ]; then
    die "/dev/mapper/$name is already open (an interrupted run?): x299-btrfs-migrate umount"
  fi
  cryptsetup open "$@" --key-file "$KEY" "$dev" "$name"
  MAPS+=("$name")
}

close_map() {
  cryptsetup close "$1"
  local kept=() m
  for m in "${MAPS[@]}"; do [ "$m" = "$1" ] || kept+=("$m"); done
  MAPS=("${kept[@]}")
}

# Close what others (udisks) unlocked on <luks partition>, after unmounting it.
release_luks() {
  local m
  for m in $(lsblk -nrpo NAME,TYPE "$1" | awk '$2 == "crypt" { print $1 }'); do
    release_mounts "$m"
    say "Closing $m"
    run cryptsetup close "${m##*/}"
  done
}

release_disk() {
  local p
  for p in $(lsblk -nrpo NAME,TYPE "$DISK" | awk '$2 == "part" { print $1 }'); do
    release_mounts "$p"
    cryptsetup isLuks "$p" 2>/dev/null && release_luks "$p"
  done
  return 0
}

reread_table() {
  udevadm settle || true
  run blockdev --rereadpt "$DISK" || run partx -u "$DISK"
  udevadm settle || true
}

NEW=$MNT/new
mount_new() { # mount_new [--with-boot]
  local dev=/dev/mapper/$NEW_MAP opts=compress=zstd,noatime
  mnt "$NEW" -t btrfs -o "subvol=@root,$opts" "$dev"
  mnt "$NEW/nix" -t btrfs -o "subvol=@nix,$opts" "$dev"
  mnt "$NEW/persist" -t btrfs -o "subvol=@persist,$opts" "$dev"
  mnt "$NEW/home" -t btrfs -o "subvol=@home,$opts" "$dev"
  if [ "${1:-}" = --with-boot ]; then
    mnt "$NEW/boot" -o fmask=0077,dmask=0077 "$ESP_PART"
  fi
}

prepared_system() {
  [ -s "$STAGE/persist.txt" ] || die "$STAGE/persist.txt missing: run 'prepare' first"
  local s
  s=$(readlink -f "$STAGE/system" || true)
  [ -n "$s" ] && [ -e "$s/bin/switch-to-configuration" ] || die "prebuilt system missing ($STAGE/system): rerun 'prepare'"
  printf '%s\n' "$s"
}

# ----------------------------------------------------------------- phases --

phase_prepare() {
  need_root
  run mkdir -p "$STAGE"
  say "Building nixosConfigurations.X299-SSD-btrfs (kept alive by $STAGE/system)"
  run nix build --impure "path:$REPO#nixosConfigurations.X299-SSD-btrfs.config.system.build.toplevel" \
    --out-link "$STAGE/system"
  say "Listing the paths the btrfs system persists"
  local list
  # shellcheck disable=SC2016  # Nix code, not shell
  list=$(nix eval --impure --raw \
    "path:$REPO#nixosConfigurations.X299-SSD-btrfs.config.environment.persistence" \
    --apply 'p: let x = p."/persist"; in builtins.concatStringsSep "\n"
      (map (d: "dir ${d.dirPath}") x.directories ++ map (f: "file ${f.filePath}") x.files) + "\n"')
  if [ "$DRY" = 1 ]; then printf '%s\n' "$list"; else printf '%s\n' "$list" > "$STAGE/persist.txt"; fi
  say "Ready: $(readlink -f "$STAGE/system" 2>/dev/null || echo '(dry run)').  Next: sudo x299-btrfs-migrate check"
}

phase_check() {
  need_root
  find_devices
  say "X299 disk: $DISK ($(lsblk -dno MODEL,SIZE "$DISK" | xargs)), layout: $LAYOUT"
  lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL,MOUNTPOINTS "$DISK"
  echo "  LUKS root : ${LUKS_PART:--}"
  echo "  ESP       : ${ESP_PART:--}"
  if [ -n "$LUKS_PART" ]; then
    local inner=- m
    m=$(lsblk -nrpo NAME,TYPE "$LUKS_PART" | awk '$2 == "crypt" { print $1; exit }')
    if [ -n "$m" ]; then
      inner=$(blkid -p -s TYPE -o value "$m" 2>/dev/null || echo '?')
    elif [ -f "$KEY" ]; then
      open_map "$LUKS_PART" x299-check --readonly
      inner=$(blkid -p -s TYPE -o value /dev/mapper/x299-check 2>/dev/null || echo '?')
    else
      inner="(locked; no $KEY)"
    fi
    echo "  inside    : $inner"
  fi
  echo "  stage dir : $STAGE"
  local p
  for p in stage format copy install; do
    if done_p "$p"; then echo "  phase $p : done"; else echo "  phase $p : -"; fi
  done
}

phase_stage() {
  need_root
  find_devices
  [ "$LAYOUT" = old ] || die "the disk is not in the old layout ($LAYOUT); 'stage' ran before (see 'check')"
  ! done_p stage || die "$STAGE already holds a stage; 'rollback' or 'release-stage' it first"
  need_key
  no_automount
  check_stage_disk
  prepared_system > /dev/null
  cryptsetup open --test-passphrase --key-file "$KEY" "$LUKS_PART" ||
    die "the passphrase in $KEY does not unlock $LUKS_PART"

  local base=$STAGE need avail
  while [ ! -e "$base" ]; do base=$(dirname "$base"); done
  need=$(( $(blockdev --getsize64 "$LUKS_PART") + 2 * 1073741824 ))
  avail=$(df --output=avail -B1 "$base" | tail -1)
  echo "  image needs $(( need / 1073741824 )) GiB; $(( avail / 1073741824 )) GiB free in $base"
  [ "$avail" -gt "$need" ] || die "not enough room for the image in $STAGE"

  confirm STAGE "Unmount and lock X299's root, then copy its partition table, ESP and raw encrypted
root partition to $STAGE.  Nothing on X299 changes yet."
  release_luks "$LUKS_PART"
  release_mounts "$ESP_PART"

  if [ "$DRY" = 0 ]; then
    say "Checking the ext4 root (read-only)"
    open_map "$LUKS_PART" "$OLD_MAP" --readonly
    [ "$(blkid -p -s TYPE -o value "/dev/mapper/$OLD_MAP")" = ext4 ] || die "no ext4 inside $LUKS_PART"
    e2fsck -fn "/dev/mapper/$OLD_MAP" || die "e2fsck found problems: boot X299-SSD once, shut down cleanly, retry"
    close_map "$OLD_MAP"
  fi

  run mkdir -p "$STAGE"
  local esp_start
  esp_start=$(lsblk -ndo START "$ESP_PART" | tr -d ' ')
  if [ "$DRY" = 0 ]; then
    # Found again by rollback should the LUKS header be gone.
    local id
    id=$(find /dev/disk/by-id -lname "*/${DISK##*/}" ! -name 'wwn-*' -print | sort | head -1)
    printf '%s\n' "${id:-$DISK}" > "$STAGE/disk"
    sgdisk -p "$DISK" > "$STAGE/layout-before.txt"
    save_partitions > "$STAGE/partitions.txt"
    printf '%s\n' "$(blockdev --getsize64 "$DISK")" > "$STAGE/disk-bytes"
  fi
  say "Saving the partition table and the first $esp_start sectors (MBR, GPT, BIOS boot)"
  run sgdisk --backup="$STAGE/gpt.bin" "$DISK"
  run dd if="$DISK" of="$STAGE/head.img" bs=512 count="$esp_start" status=none conv=fsync
  say "Saving the ESP's files"
  mnt_real "$MNT/esp" -o ro "$ESP_PART"
  run tar -C "$MNT/esp" -cf "$STAGE/esp.tar" .
  unmnt_last
  run cryptsetup luksHeaderBackup "$LUKS_PART" --header-backup-file "$STAGE/luks-header.img"

  say "Imaging $LUKS_PART raw (still encrypted) into $IMAGE"
  if [ "$DRY" = 1 ]; then
    echo "[dry-run] dd if=$LUKS_PART | tee $IMAGE | sha256sum"
  else
    dd if="$LUKS_PART" bs=16M iflag=direct status=progress | tee "$IMAGE" | sha256sum | awk '{ print $1 }' > "$STAGE/image.sha256"
    sync -f "$IMAGE"
    [ "$(stat -c %s "$IMAGE")" = "$(blockdev --getsize64 "$LUKS_PART")" ] || die "image size differs from $LUKS_PART"
    say "Verifying the image from disk"
    [ "$(dd if="$IMAGE" bs=16M iflag=direct status=none | sha256sum | awk '{ print $1 }')" = "$(cat "$STAGE/image.sha256")" ] ||
      die "the image on $STAGE does not match $LUKS_PART"
    cryptsetup open --test-passphrase --key-file "$KEY" "$IMAGE" || die "the image does not unlock"
  fi
  mark stage
  say "Rollback point ready in $STAGE.  Next: sudo x299-btrfs-migrate format"
}

phase_format() {
  need_root
  find_devices
  done_p stage || die "run 'stage' first"
  need_key
  no_automount
  cryptsetup open --test-passphrase --key-file "$KEY" "$IMAGE" || die "the passphrase in $KEY does not unlock the staged root"

  # Geometry from the saved old table: the new ESP starts where BIOS boot started, the new
  # LUKS ends where the old one ended (just before DATA).
  local esp_start luks_end data_start esp_end luks_start old_esp_guid old_luks_guid
  esp_start=$(awk '$2 == 1 { print $3 }' "$STAGE/partitions.txt")
  luks_end=$(awk '$2 == 3 { print $3 + $4 / 512 - 1 }' "$STAGE/partitions.txt")
  data_start=$(awk '$2 == 4 { print $3 }' "$STAGE/partitions.txt")
  old_esp_guid=$(awk '$2 == 2 { print $6 }' "$STAGE/partitions.txt")
  old_luks_guid=$(awk '$2 == 3 { print $6 }' "$STAGE/partitions.txt")
  esp_end=$(( esp_start + ESP_MIB * 2048 - 1 ))
  luks_start=$(( esp_end + 1 ))
  [ -n "$esp_start" ] && [ -n "$luks_end" ] && [ "$data_start" = $(( luks_end + 1 )) ] ||
    die "unexpected saved layout in $STAGE/partitions.txt"
  [ $(( luks_end - luks_start )) -gt $(( 1024 * 2048 )) ] || die "no room for the root after a ${ESP_MIB} MiB ESP"

  if [ "$LAYOUT" = old ]; then
    confirm FORMAT "Rewrite the partition table of $DISK the CRUCIAL way:
  p1 EFI ${ESP_MIB} MiB (new, empty), p2 new LUKS -> btrfs ($(( (luks_end - luks_start + 1) / 2097152 )) GiB)
  ERASES the old root and ESP (the stage in $STAGE is the only copy afterwards);
  DATA and Virtual Windows become p3 and p4 (renumbered only, contents untouched)."
    release_disk
    say "Writing the new partition table"
    run sgdisk -d 1 -d 2 -d 3 -r 4:3 -r 5:4 \
      -n "1:$esp_start:$esp_end" -t 1:EF00 -c 1:EFI -u "1:$old_esp_guid" \
      -n "2:$luks_start:$luks_end" -t 2:8300 -c 2:cryptroot -u "2:$old_luks_guid" "$DISK"
    reread_table
  elif [ "$LAYOUT" = new ] && ! done_p format; then
    confirm FORMAT "Partitions are already CRUCIAL-style but 'format' did not finish: redo the ESP,
LUKS and btrfs on $DISK partitions 1 and 2."
    release_disk
  else
    die "the disk is already formatted ($LAYOUT); 'rollback' first to start over"
  fi
  [ "$DRY" = 1 ] && return 0

  local p1 p2
  p1=$(part_of "$DISK" 1)
  p2=$(part_of "$DISK" 2)
  [ "$(lsblk -ndo START "$p1" | tr -d ' ')" = "$esp_start" ] && [ "$(lsblk -ndo START "$p2" | tr -d ' ')" = "$luks_start" ] ||
    die "the kernel does not show the new table on $DISK (busy partition?): unplug/replug, then rerun 'format'"
  local n uuid
  for n in 4 5; do
    uuid=$(awk -v n="$n" '$2 == n { print $7 }' "$STAGE/partitions.txt")
    [ "$uuid" = - ] || [ "$(lsblk -ndo UUID "$(part_of "$DISK" $(( n - 1 )))")" = "$uuid" ] ||
      die "partition $(( n - 1 )) is not the old partition $n (UUID $uuid)"
  done

  say "New ESP on $p1"
  wipefs -a "$p1" > /dev/null
  mkfs.vfat -F 32 -i "${ESP_UUID//-/}" -n EFI "$p1" > /dev/null
  say "New LUKS2 container on $p2 (UUID $LUKS_UUID, same passphrase)"
  wipefs -a "$p2" > /dev/null
  cryptsetup luksFormat --batch-mode --type luks2 --uuid "$LUKS_UUID" --key-file "$KEY" "${LUKS_FORMAT_ARGS[@]}" "$p2"
  open_map "$p2" "$NEW_MAP"
  mkfs.btrfs -q -f -L nixos "/dev/mapper/$NEW_MAP"
  local top=$MNT/top s
  mnt "$top" -t btrfs -o subvol=/ "/dev/mapper/$NEW_MAP"
  for s in $SUBVOLS; do btrfs subvolume create "$top/$s" > /dev/null; done
  udevadm settle || true
  mark format
  say "Next: sudo x299-btrfs-migrate copy"
}

# Store paths of the users' nix profiles in the old root (all generations).
profile_paths() { # profile_paths <old root>
  local l t
  for l in "$1"/home/*/.local/state/nix/profiles/*-link "$1/nix/var/nix/profiles/per-user/$TARGET_USER"/*-link; do
    [ -L "$l" ] || continue
    t=$(readlink "$l")
    case "$t" in /nix/store/*) [ -e "$1$t" ] && printf '%s %s\n' "${l#"$1"}" "$t" ;; esac
  done
  return 0
}

phase_copy() {
  need_root
  find_devices
  { [ "$LAYOUT" = new ] && done_p format; } || die "run 'format' first"
  need_key
  no_automount
  local system
  system=$(prepared_system)

  local old=$MNT/old
  open_map "$IMAGE" "$OLD_MAP" --readonly
  mnt_real "$old" -o ro,noload "/dev/mapper/$OLD_MAP"
  open_map "$LUKS_PART" "$NEW_MAP"
  [ "$(blkid -p -s TYPE -o value "/dev/mapper/$NEW_MAP")" = btrfs ] || die "expected btrfs inside $LUKS_PART"
  mount_new

  say "Copying the system closure into the new store"
  run nix copy --extra-experimental-features nix-command --no-check-sigs --to "local?root=$NEW" "$system"

  say "Copying the users' nix profiles from the old store"
  local links=() paths=() l t
  while read -r l t; do links+=("$l"); paths+=("$t"); done < <(profile_paths "$old")
  if [ ${#paths[@]} -gt 0 ]; then
    printf '  %s\n' "${links[@]}"
    run nix copy --extra-experimental-features 'nix-command read-only-local-store' \
      --no-check-sigs --from "local?root=$old&read-only=true" --to "local?root=$NEW" "${paths[@]}"
    run mkdir -p "$NEW/nix/var/nix/gcroots/auto" "$NEW/nix/var/nix/profiles/per-user"
    # Profiles under /home are GC roots only through these links (the old store's
    # gcroots/auto are not copied); per-user profiles in /nix are roots where they lie.
    for l in "${links[@]}"; do
      case "$l" in
        /nix/var/nix/profiles/*) ;;
        *) run ln -sfn "$l" "$NEW/nix/var/nix/gcroots/auto/x299-$(printf '%s' "$l" | sha256sum | cut -c1-32)" ;;
      esac
    done
    if [ -d "$old/nix/var/nix/profiles/per-user/$TARGET_USER" ]; then
      run rsync -a "$old/nix/var/nix/profiles/per-user/$TARGET_USER" "$NEW/nix/var/nix/profiles/per-user/"
    fi
  fi

  say "Listing what the boot sweep would remove from /home (not copied)"
  local excl
  excl=$(mktemp -p /run x299-excludes.XXXXXX)
  TMPFILES+=("$excl")
  local sweep_out u
  sweep_out=$(mktemp -p /run x299-sweep.XXXXXX)
  TMPFILES+=("$sweep_out")
  [ -d "$old/home/$TARGET_USER" ] || die "no /home/$TARGET_USER in the old root"
  # Errors only mean some folders could not be listed: those are copied, not lost.
  python3 -I "$SWEEP" --home-dir "$old/home/$TARGET_USER" --dry-run > "$sweep_out" ||
    warn "the sweep's dry run reported errors (see above); what it could not list is copied"
  tail -1 "$sweep_out"
  python3 -I "$SWEEP_EXCLUDES" "$old/home" "$TARGET_USER/.cache/" --output "$excl" < "$sweep_out"

  say "Copying /home (without the sweep's list and ~/.cache)"
  run rsync -aHAXS --numeric-ids --info=progress2 --from0 --exclude-from="$excl" "$old/home/" "$NEW/home/"

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
  done < <(cat "$STAGE/persist.txt"; echo)

  say "Carrying the password hashes over (mutableUsers = false reads them from /persist)"
  run install -d -m 0700 "$NEW/persist/passwords"
  local hash
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

  run sync -f "$NEW/home"
  mark copy
  say "Copied: $(df -h --output=used "$NEW" | tail -1 | xargs) used on the new root.  Next: sudo x299-btrfs-migrate install"
}

phase_install() {
  need_root
  find_devices
  { [ "$LAYOUT" = new ] && done_p copy; } || die "run 'copy' first"
  need_key
  no_automount
  local system
  system=$(prepared_system)
  release_mounts "$ESP_PART"
  open_map "$LUKS_PART" "$NEW_MAP"
  mount_new --with-boot
  # Activation inside the chroot should see the persisted uid/gid map, as the real boot
  # will (impermanence bind-mounts it in the initrd).
  if [ -d "$NEW/persist/var/lib/nixos" ]; then
    mnt "$NEW/var/lib/nixos" --bind "$NEW/persist/var/lib/nixos"
  fi
  [ -e "$NEW$system" ] || die "the system is not in the new store: rerun 'copy'"
  say "Setting the system profile to $system"
  run nix-env --store "$NEW" -p "$NEW/nix/var/nix/profiles/system" --set "$system"
  run mkdir -p "$NEW/etc"
  run touch "$NEW/etc/NIXOS"
  run ln -sfn /proc/mounts "$NEW/etc/mtab"
  say "Installing the boot loader onto $ESP_PART"
  run nixos-enter --root "$NEW" -c \
    "NIXOS_INSTALL_BOOTLOADER=1 /nix/var/nix/profiles/system/bin/switch-to-configuration boot"
  run sync -f "$NEW/boot"
  mark install
  say "Installed.  Unplug the disk, boot X299-SSD and follow MIGRATE.md step 5."
}

phase_rollback() {
  need_root
  find_devices
  done_p stage || die "no stage in $STAGE: nothing to roll back to"
  if [ "$LAYOUT" = old ] && ! done_p format; then
    die "the disk was never formatted: nothing to roll back ('release-stage' deletes the stage)"
  fi
  need_key
  no_automount
  [ "$(cat "$STAGE/disk-bytes")" = "$(blockdev --getsize64 "$DISK")" ] || die "$DISK is not the staged disk (size differs)"
  confirm ROLLBACK "Put back the old partition table, ESP and encrypted ext4 root of $DISK from $STAGE.
Everything on the new layout's ESP and root is lost; DATA and Virtual Windows are untouched."
  release_disk
  if [ "$DRY" = 1 ]; then
    echo "[dry-run] restore GPT, head, raw root, ESP files from $STAGE"
    return 0
  fi
  say "Restoring the partition table and first sectors"
  sgdisk --load-backup="$STAGE/gpt.bin" "$DISK" > /dev/null
  dd if="$STAGE/head.img" of="$DISK" bs=512 conv=fsync,notrunc status=none
  reread_table
  local p2 p3 n start
  for n in 1 2 3 4 5; do
    start=$(awk -v n="$n" '$2 == n { print $3 }' "$STAGE/partitions.txt")
    [ -z "$start" ] || [ "$(lsblk -ndo START "$(part_of "$DISK" "$n")" | tr -d ' ')" = "$start" ] ||
      die "partition $n does not start at $start after restoring the table: unplug/replug, rerun 'rollback'"
  done
  p2=$(part_of "$DISK" 2)
  p3=$(part_of "$DISK" 3)
  [ "$(blockdev --getsize64 "$p3")" = "$(stat -c %s "$IMAGE")" ] || die "partition 3 and the image differ in size"
  say "Writing the encrypted root back to $p3"
  dd if="$IMAGE" of="$p3" bs=16M oflag=direct conv=fsync status=progress
  say "Recreating the old ESP on $p2"
  wipefs -a "$p2" > /dev/null
  mkfs.vfat -F 32 -i "${ESP_UUID//-/}" -n EFI "$p2" > /dev/null
  mnt_real "$MNT/esp" "$p2"
  tar -C "$MNT/esp" --no-same-owner -xf "$STAGE/esp.tar"
  unmnt_last
  udevadm settle || true
  open_map "$p3" "$OLD_MAP" --readonly
  e2fsck -fn "/dev/mapper/$OLD_MAP" || die "the restored root does not check clean"
  rm -f "$STAGE"/{format,copy,install}.done
  say "Old layout back.  X299 boots its previous (ext4) generation; the stage stays until 'release-stage'."
}

phase_release_stage() {
  need_root
  find_devices
  done_p stage || die "no stage in $STAGE"
  if [ "$LAYOUT" = old ] && ! done_p format; then
    confirm RELEASE "The disk was never formatted: delete the unused stage $STAGE."
  else
    { [ "$LAYOUT" = new ] && done_p install; } || die "the new layout is not installed: keep the stage"
    need_key
    open_map "$LUKS_PART" "$NEW_MAP" --readonly
    local top=$MNT/top
    mnt_real "$top" -o ro,subvol=/ "/dev/mapper/$NEW_MAP"
    [ -n "$(find "$top/@persist/var/log/journal" -type f -newer "$STAGE/install.done" -print -quit 2>/dev/null)" ] ||
      die "X299 has not booted the new layout yet (no journal written since 'install'): keep the stage"
    confirm RELEASE "Delete the rollback stage $STAGE (image, table, ESP files)."
  fi
  run rm -f "$IMAGE" "$STAGE"/{gpt.bin,head.img,esp.tar,luks-header.img,image.sha256,disk,disk-bytes} \
    "$STAGE"/{layout-before,partitions,persist}.txt "$STAGE"/{stage,format,copy,install}.done "$STAGE"/system
  run rmdir "$STAGE"
  say "Stage released."
}

phase_umount() {
  need_root
  local m
  for m in $(findmnt -rno TARGET | grep "^$MNT" | sort -r); do umount "$m" || umount -l "$m"; done
  for m in "$NEW_MAP" "$OLD_MAP" x299-check; do
    [ ! -e "/dev/mapper/$m" ] || cryptsetup close "$m"
  done
  say "Unmounted $MNT and closed the X299 mappings."
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
  *) usage; exit 2 ;;
esac
