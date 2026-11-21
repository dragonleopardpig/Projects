# m90-btrfs-migrate: move M90aPro from its ext4 disk to the impermanent btrfs
# layout on its other SSD, then (later) grow that btrfs onto the old disk so the
# two SSDs form one pool.  Packaged by packages/m90-btrfs-migrate.nix (on the
# PortableSSD, and on the btrfs M90aPro for the extend phases); the procedure
# is hosts/M90aPro/MIGRATE.md.
#
#   prepare         on the PortableSSD, as thinky: build the btrfs system and
#                   disko's format script, list the persisted paths
#   check           on the PortableSSD: identify both disks, show what is done
#   format          disko on the NEW disk: ESP, swap, LUKS -> btrfs [ERASES NEW DISK]
#   copy            /nix, /home, persisted state, password hashes from the old
#                   disk (opened read-only), plus the prepared system closure
#   install         system profile + GRUB on the new ESP (firmware entry NixOS-pool)
#   extend-prepare  on the btrfs M90aPro: the OLD disk becomes one LUKS
#                   partition "m90-pool2"                          [ERASES OLD DISK]
#   extend          after a reboot with custom.m90Pool.secondDisk: add it to the pool
#   umount          undo mounts / close LUKS after an interrupted phase
#
# The old disk is never written before extend-prepare: until then it is the
# fallback (firmware boot entry "NixOS-boot").
#
# Options: --dry-run (print destructive commands instead of running them).
# Environment overrides (the VM tests use them): M90_SOURCE_UUID, M90_TARGET,
# M90_SECOND, M90_USER, M90_STATE, M90_REPO, M90_KEY_FILE, M90_YES=1,
# M90_LUKS_ARGS (extra luksFormat options).

# Also set by writeShellApplication; repeated for `bash m90-btrfs-migrate.sh`.
set -euo pipefail

SOURCE_UUID=${M90_SOURCE_UUID:-e4268bbb-c627-4904-b67f-8a76fe0cbf52}
TARGET=${M90_TARGET:-/dev/disk/by-id/nvme-SAMSUNG_MZVL8256HFJD-00BLL_S7XLNE0Y733872}
SECOND=${M90_SECOND:-/dev/disk/by-id/nvme-SAMSUNG_MZVL8256HFJD-00BLL_S7XLNE0Y733865}
TARGET_USER=${M90_USER:-thinky}
STATE=${M90_STATE:-/home/$TARGET_USER/.local/state/m90-migration}
REPO=${M90_REPO:-/home/$TARGET_USER/Projects/NixOS}
# disko.nix reads the new disk's passphrase from here (RAM only).
KEY_FILE=${M90_KEY_FILE:-/dev/shm/m90-luks-key}
FLAKE_ATTR=${M90_FLAKE_ATTR:-M90aPro}  # the btrfs layout is the default now
MNT=/mnt/m90
NEW=$MNT/new          # = disko.rootMountPoint in layouts.nix
OLD=$MNT/old
OLD_MAPPER=m90-old
NEW_MAPPER=cryptpool  # = the luks name in disko.nix
SECOND_MAPPER=cryptpool2
NEW_ROOT_LABEL="disk-m90-root"
NEW_ESP_LABEL="disk-m90-ESP"
POOL2_LABEL="m90-pool2"

usage() {
  cat <<'EOF'
usage: m90-btrfs-migrate [--dry-run] PHASE      (hosts/M90aPro/MIGRATE.md)
  prepare         on the PortableSSD, as thinky: build the btrfs system
  check           identify the old and the new disk, show which phases ran
  format          disko on the new disk                      [ERASES NEW DISK]
  copy            /nix, /home, persisted state, passwords -> the new disk
  install         system profile + GRUB on the new ESP
  extend-prepare  on the btrfs M90aPro: old disk -> LUKS "m90-pool2"  [ERASES OLD DISK]
  extend          after the reboot with custom.m90Pool.secondDisk: add it to the pool
  umount          undo mounts / close LUKS after an interrupted phase
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
# inspection runs directly, so --dry-run still checks the disk identities.
run() {
  if [ "$DRY" = 1 ]; then
    printf '[dry-run]'; printf ' %q' "$@"; printf '\n'
  else
    "$@"
  fi
}

confirm() {
  local word=$1 what=$2 reply
  [ "${M90_YES:-0}" = 1 ] && return 0
  [ "$DRY" = 1 ] && return 0
  printf '\n%s\nType %s to continue: ' "$what" "$word"
  read -r reply
  [ "$reply" = "$word" ] || die "not confirmed; nothing changed"
}

MOUNTS=()
OPENED=()
cleanup() {
  local i
  for ((i = ${#MOUNTS[@]} - 1; i >= 0; i--)); do
    umount "${MOUNTS[$i]}" 2>/dev/null || umount -l "${MOUNTS[$i]}" 2>/dev/null || true
  done
  MOUNTS=()
  for ((i = ${#OPENED[@]} - 1; i >= 0; i--)); do
    cryptsetup close "${OPENED[$i]}" 2>/dev/null || true
  done
  OPENED=()
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

# A desktop on the PortableSSD may have auto-mounted a partition; disko and
# cryptsetup refuse busy devices, so let go of those mounts first.
release_mounts() { # release_mounts <device>
  local t
  for t in $(findmnt -rno TARGET -S "$1" 2>/dev/null | sort -r); do
    say "Unmounting $1 from $t (auto-mounted)"
    run umount "$t"
  done
}

need_root() { [ "$(id -u)" = 0 ] || die "run as root (sudo $0 $PHASE)"; }

# What an empty partition still holds after Windows and a desktop saw it: the
# indexer's state, an empty Recycle Bin, empty trash folders.  Anything put in
# the bin or the trash is not a placeholder.
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

disk_of() { # disk_of <partition or mapper>: the whole disk below it
  local dev
  dev=$(readlink -f "$1")
  lsblk -nrpso NAME,TYPE "$dev" 2>/dev/null | awk '$2 == "disk" { print $1; exit }'
}

running_disks() { # the disks holding the running root
  local src
  src=$(findmnt -no SOURCE / | sed 's/\[.*//')
  lsblk -nrpso NAME,TYPE "$src" 2>/dev/null | awk '$2 == "disk" { print $1 }'
}

# ---------------------------------------------------------------- devices --

SOURCE_PART="" SOURCE_DISK="" TARGET_DISK=""

find_source() {
  SOURCE_PART=$(readlink -f "/dev/disk/by-uuid/$SOURCE_UUID" 2>/dev/null || true)
  [ -b "$SOURCE_PART" ] || die "the old system disk (LUKS UUID $SOURCE_UUID) is not here"
  cryptsetup isLuks "$SOURCE_PART" || die "$SOURCE_PART is not LUKS"
  SOURCE_DISK=$(disk_of "$SOURCE_PART")
}

find_target() {
  [ -b "$TARGET" ] || die "the new disk $TARGET is not here"
  TARGET_DISK=$(readlink -f "$TARGET")
  [ -n "$SOURCE_DISK" ] || return 0
  [ "$TARGET_DISK" != "$SOURCE_DISK" ] || die "$TARGET is the old system disk itself"
}

# Format, copy and install run from the PortableSSD, never from either disk.
need_rescue_system() {
  local d
  for d in $(running_disks); do
    [ "$d" != "$SOURCE_DISK" ] || die "the running system is on the old disk $SOURCE_DISK; boot the PortableSSD"
    [ "$d" != "$TARGET_DISK" ] || die "the running system is on the new disk $TARGET_DISK; boot the PortableSSD"
  done
}

part_on_target() { # part_on_target <partlabel>: that partition, checked to be on the new disk
  local p
  p=$(readlink -f "/dev/disk/by-partlabel/$1" 2>/dev/null || true)
  [ -b "$p" ] || die "no partition labelled $1: run 'format' first"
  [ "$(disk_of "$p")" = "$TARGET_DISK" ] || die "partition $1 ($p) is not on the new disk $TARGET_DISK"
  echo "$p"
}

# open <partition> <mapper> [--readonly]: real even under --dry-run (not destructive).
# Tries the key file first; for the old disk, falls back to typing its passphrase.
open_luks() {
  local part=$1 name=$2 ro=${3:-} other args
  other=$(lsblk -nrpo NAME,TYPE "$part" | awk '$2 == "crypt" { print $1 }' | grep -vx "/dev/mapper/$name" || true)
  [ -z "$other" ] || die "$part is already unlocked as $other (file manager?): close it with 'cryptsetup close ${other##*/}'"
  if [ -e "/dev/mapper/$name" ]; then
    [ "$(lsblk -nrps -o NAME "/dev/mapper/$name" | sed -n 2p)" = "$part" ] || die "/dev/mapper/$name exists but is not $part"
    return 0
  fi
  args=(open)
  [ -n "$ro" ] && args+=(--readonly)
  say "Unlocking $part as /dev/mapper/$name"
  if [ -s "$KEY_FILE" ] && cryptsetup "${args[@]}" --key-file "$KEY_FILE" "$part" "$name" 2>/dev/null; then
    :
  elif [ "$name" = "$OLD_MAPPER" ]; then
    echo "  (the key file does not open it: type the old disk's passphrase)"
    cryptsetup "${args[@]}" "$part" "$name"
  else
    die "the passphrase in $KEY_FILE does not open $part"
  fi
  OPENED+=("$name")
}

mount_old() {
  open_luks "$SOURCE_PART" "$OLD_MAPPER" --readonly
  [ "$(blkid -p -s TYPE -o value "/dev/mapper/$OLD_MAPPER")" = ext4 ] || die "expected ext4 on the old disk"
  mnt_real "$OLD" -o ro,noload "/dev/mapper/$OLD_MAPPER"
}

mount_new() { # mount_new [--with-boot]
  local root dev=/dev/mapper/$NEW_MAPPER opts=compress=zstd,noatime
  root=$(part_on_target "$NEW_ROOT_LABEL")
  open_luks "$root" "$NEW_MAPPER"
  [ "$(blkid -p -s TYPE -o value "$dev")" = btrfs ] || die "expected btrfs on the new disk"
  mnt "$NEW" -t btrfs -o "subvol=@root,$opts" "$dev"
  mnt "$NEW/nix" -t btrfs -o "subvol=@nix,$opts" "$dev"
  mnt "$NEW/persist" -t btrfs -o "subvol=@persist,$opts" "$dev"
  mnt "$NEW/home" -t btrfs -o "subvol=@home,$opts" "$dev"
  if [ "${1:-}" = --with-boot ]; then
    local esp
    esp=$(part_on_target "$NEW_ESP_LABEL")
    release_mounts "$esp"
    mnt "$NEW/boot" -o fmask=0077,dmask=0077 "$esp"
  fi
}

mark() { run mkdir -p "$STATE"; run touch "$STATE/$1.done"; }
done_p() { [ -e "$STATE/$1.done" ]; }
prepared() { # prepared <name>: the prepare output, which must exist
  local p
  p=$(readlink -f "$STATE/$1" 2>/dev/null || true)
  [ -n "$p" ] && [ -e "$p" ] || die "$STATE/$1 is missing: run 'prepare' first (as $TARGET_USER)"
  echo "$p"
}

ensure_key() { # the new disk's passphrase in $KEY_FILE (RAM), typed twice
  [ -s "$KEY_FILE" ] && return 0
  [ "$DRY" = 1 ] && return 0
  local a b
  read -rsp "Passphrase for the new disk (use the old disk's one): " a; echo
  read -rsp "Again: " b; echo
  [ -n "$a" ] && [ "$a" = "$b" ] || die "passphrases empty or not the same"
  (umask 077; printf '%s' "$a" > "$KEY_FILE")
}

# ----------------------------------------------------------------- phases --

phase_prepare() {
  [ "$(id -u)" != 0 ] || die "run 'prepare' as $TARGET_USER, not root"
  local attr="path:$REPO#nixosConfigurations.$FLAKE_ATTR.config"
  run mkdir -p "$STATE"
  say "Building nixosConfigurations.$FLAKE_ATTR (kept alive by $STATE/system)"
  run nix build "$attr.system.build.toplevel" --out-link "$STATE/system"
  say "Building disko's format script for the new disk"
  run nix build "$attr.system.build.destroyFormatMount" --out-link "$STATE/disko-format"
  local list device
  # shellcheck disable=SC2016  # Nix code, not shell
  list=$(nix eval --raw "$attr.environment.persistence" \
    --apply 'p: let x = p."/persist"; in builtins.concatStringsSep "\n"
      (map (d: "dir ${d.dirPath}") x.directories ++ map (f: "file ${f.filePath}") x.files) + "\n"')
  device=$(nix eval --raw "$attr.disko.devices.disk.m90.device")
  [ "$device" = "$TARGET" ] || die "disko.nix formats $device, expected $TARGET"
  # $(...) strips the final newline; without it `read` would drop the last entry.
  if [ "$DRY" = 1 ]; then
    printf '%s\n' "$list"
  else
    printf '%s\n' "$list" > "$STATE/persist.txt"
    printf '%s\n' "$device" > "$STATE/disko-device"
  fi
  say "Ready: $(readlink -f "$STATE/system" 2>/dev/null || echo '(dry run)').  Next: sudo m90-btrfs-migrate check"
}

# What the old root holds outside /nix, /home and the persisted list: shown by
# 'check' so nothing important is left behind unnoticed.
not_carried_over() {
  local d e kind path covered
  for d in root opt srv usr/local; do
    [ -d "$OLD/$d" ] || continue
    find "$OLD/$d" -mindepth 1 -maxdepth 1 -printf "  /$d/%P\n" 2>/dev/null
  done
  [ -e "$STATE/persist.txt" ] || return 0
  for e in "$OLD"/var/lib/*; do
    [ -e "$e" ] || continue
    covered=0
    while read -r kind path; do
      [ -n "$path" ] || continue
      case "/var/lib/${e##*/}" in "$path" | "$path"/*) covered=1 ;; esac
      case "$path" in "/var/lib/${e##*/}"/*) covered=1 ;; esac
    done < <(cat "$STATE/persist.txt"; echo)
    [ "$covered" = 1 ] || echo "  /var/lib/${e##*/}"
  done
  # Regular files in /etc that NixOS did not put there itself (its copies are
  # listed in /etc/.clean; the rest are symlinks into the store).
  find "$OLD/etc" -xdev -type f \
    ! -name passwd ! -name group ! -name shadow ! -name gshadow ! -name subuid ! -name subgid \
    ! -name machine-id ! -name NIXOS ! -name '.clean' ! -name '.updated' ! -name resolv.conf \
    ! -name adjtime ! -name '*-' ! -path '*/NetworkManager/system-connections/*' \
    -printf '%P\n' 2>/dev/null |
    { if [ -s "$OLD/etc/.clean" ]; then grep -vxF -f "$OLD/etc/.clean" || true; else cat; fi; } |
    sed 's|^|  /etc/|'
}

phase_check() {
  need_root
  find_source
  find_target
  say "Old system disk: $SOURCE_DISK ($(lsblk -dno MODEL,SERIAL,SIZE "$SOURCE_DISK" | xargs))"
  lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL,MOUNTPOINTS "$SOURCE_DISK"
  say "New disk: $TARGET_DISK ($(lsblk -dno MODEL,SERIAL,SIZE "$TARGET_DISK" | xargs))"
  lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL,MOUNTPOINTS "$TARGET_DISK"
  local p
  for p in format copy install; do
    if done_p "$p"; then echo "  phase $p : done"; else echo "  phase $p : -"; fi
  done
  need_rescue_system
  mount_old
  echo "  old root uses $(df -h --output=used "$OLD" | tail -1 | xargs) of $(df -h --output=size "$OLD" | tail -1 | xargs)"
  echo "  not carried over (outside /nix, /home and the persisted list):"
  not_carried_over | head -60 || true
}

target_must_be_empty() {
  local part type probe=$MNT/probe entries
  while read -r part; do
    [ "$part" = "$TARGET_DISK" ] && continue
    type=$(blkid -p -s TYPE -o value "$part" 2>/dev/null || true)
    case "$type" in
      "") continue ;;  # no filesystem (e.g. Microsoft reserved)
      crypto_LUKS | BitLocker | LVM2_member | linux_raid_member | swap)
        die "$part ($type) cannot be checked for files: clear it first" ;;
    esac
    release_mounts "$part"
    mnt_real "$probe" -o ro "$part"
    entries=$(find "$probe" -mindepth 1 -maxdepth 3 -printf '%y %P\n' 2>/dev/null |
      while read -r kind rel; do placeholder "$kind" "$rel" || echo "$rel"; done | head -20 || true)
    umount "$probe"
    unset 'MOUNTS[${#MOUNTS[@]}-1]'
    [ -z "$entries" ] || die "$part ($type) on the new disk is not empty; move these first:
$entries"
    release_mounts "$part"
  done < <(lsblk -nrpo NAME "$TARGET_DISK")
}

phase_format() {
  need_root
  find_source
  find_target
  need_rescue_system
  done_p format && die "'format' ran already (see 'check'); remove $STATE/format.done to redo it"
  local script device ids
  script=$(prepared disko-format)/bin/disko-destroy-format-mount
  [ -x "$script" ] || die "$script missing: rerun 'prepare'"
  device=$(cat "$STATE/disko-device" 2>/dev/null || true)
  [ "$device" = "$TARGET" ] || die "the prepared disko script formats '$device', not $TARGET: rerun 'prepare'"
  # Every disk the script would touch must be the new one.
  ids=$({ grep -oE '/dev/disk/by-id/[A-Za-z0-9._:-]+' "$script" || true; } | sed 's/-part[0-9]*$//' | sort -u)
  [ -z "$ids" ] || [ "$ids" = "$TARGET" ] || die "the disko script names other disks: $ids"
  grep -qF -- "$SOURCE_UUID" "$script" && die "the disko script mentions the old disk"

  say "Checking the new disk $TARGET_DISK is empty"
  target_must_be_empty

  ensure_key
  if [ "$DRY" = 0 ] && ! cryptsetup open --test-passphrase --key-file "$KEY_FILE" "$SOURCE_PART" 2>/dev/null; then
    warn "this passphrase does not open the old disk: once both disks are in the pool, boot asks twice"
  fi
  confirm FORMAT "ERASE the new disk $TARGET_DISK ($(lsblk -dno MODEL,SERIAL "$TARGET_DISK" | xargs)):
ESP + swap + LUKS '$NEW_MAPPER' -> btrfs (@root @nix @persist @home).
The old system disk $SOURCE_DISK is not touched."
  run "$script" --yes-wipe-all-disks
  # Later phases mount what they need themselves.
  run umount -R "$NEW"
  run cryptsetup close "$NEW_MAPPER"
  mark format
  say "Next: sudo m90-btrfs-migrate copy"
}

phase_copy() {
  need_root
  find_source
  find_target
  need_rescue_system
  [ "$DRY" = 1 ] || done_p format || die "run 'format' first"
  local system
  system=$(prepared system)
  [ -e "$STATE/persist.txt" ] || die "$STATE/persist.txt missing: rerun 'prepare'"
  mount_old
  mount_new

  local rs=(rsync -aHAXS --numeric-ids --info=progress2)
  say "Copying /nix (store, database, profiles)"
  run "${rs[@]}" "$OLD/nix/" "$NEW/nix/"

  say "Copying /home (without cargo target/ directories: rebuilt on use)"
  local ex=() t
  while read -r t; do
    ex+=("--exclude=/${t#"$OLD"/home/}/")
    echo "  skipped ${t#"$OLD"}"
  done < <(find "$OLD/home" -xdev -maxdepth 6 -path '*/target/CACHEDIR.TAG' -printf '%h\n' 2>/dev/null)
  run "${rs[@]}" "${ex[@]}" "$OLD/home/" "$NEW/home/"

  say "Copying persisted system state"
  local kind path
  while read -r kind path; do
    [ -n "$path" ] || continue
    if [ ! -e "$OLD$path" ] && [ ! -L "$OLD$path" ]; then
      echo "  (absent, will be created on boot) $path"
      continue
    fi
    run mkdir -p "$NEW/persist$(dirname "$path")"
    if [ "$kind" = dir ]; then
      run rsync -aHAXS --numeric-ids "$OLD$path/" "$NEW/persist$path/"
    else
      run rsync -aHAXS --numeric-ids "$OLD$path" "$NEW/persist$path"
    fi
    echo "  $path"
  done < <(cat "$STATE/persist.txt"; echo)

  say "Carrying the current password hashes over (mutableUsers = false reads them from /persist)"
  run install -d -m 0700 "$NEW/persist/passwords"
  local u hash
  for u in "$TARGET_USER" root; do
    hash=$(awk -F: -v u="$u" '$1 == u { print $2 }' "$OLD/etc/shadow")
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

  say "Adding the prepared system $system to the new store"
  run nix copy --no-check-sigs --to "$NEW" "$system"
  run sync
  mark copy
  say "Copied.  New disk: $(df -h --output=used "$NEW" | tail -1 | xargs) used.  Next: sudo m90-btrfs-migrate install"
}

phase_install() {
  need_root
  find_source
  find_target
  need_rescue_system
  [ "$DRY" = 1 ] || done_p copy || die "run 'copy' first"
  local system
  system=$(prepared system)
  mount_new --with-boot
  [ -e "$NEW$system" ] || [ "$DRY" = 1 ] || die "the prepared system is not in the new store: rerun 'copy'"
  # Activation inside the chroot should see the persisted uid/gid map, as the
  # real boot will (impermanence bind-mounts it in the initrd).
  if [ -d "$NEW/persist/var/lib/nixos" ] || [ "$DRY" = 1 ]; then
    mnt "$NEW/var/lib/nixos" --bind "$NEW/persist/var/lib/nixos"
  fi
  local profile=$NEW/nix/var/nix/profiles/system
  say "Setting the system profile to $system"
  run nix-env --store "$NEW" -p "$profile" --set "$system"
  # The ext4 generations came along with /nix; they would boot the old disk's
  # layout from this menu.  The old disk keeps its own.
  run nix-env --store "$NEW" -p "$profile" --delete-generations old
  run mkdir -p "$NEW/etc"
  run touch "$NEW/etc/NIXOS"
  run ln -sfn /proc/mounts "$NEW/etc/mtab"
  say "Installing the boot loader on the new ESP (firmware entry NixOS-pool)"
  run nixos-enter --root "$NEW" -c \
    "NIXOS_INSTALL_BOOTLOADER=1 /nix/var/nix/profiles/system/bin/switch-to-configuration boot"
  run sync
  mark install
  say "Installed.  Shut down, unplug the PortableSSD and boot: the firmware starts NixOS-pool."
  say "The old system stays bootable as NixOS-boot in the boot menu.  Then MIGRATE.md step B4."
}

# ------------------------------------------------------- pool (Part C) --

POOL_DEV="" POOL_PART="" POOL_DISK=""
find_pool() { # the running btrfs root, which must be the M90aPro pool
  local src opts
  src=$(findmnt -no SOURCE / | sed 's/\[.*//')
  opts=$(findmnt -no OPTIONS /)
  [ "$(findmnt -no FSTYPE /)" = btrfs ] && [[ ",$opts," == *,subvol=/@root,* ]] ||
    die "the running root is not the btrfs pool: boot the btrfs M90aPro"
  [ "$src" = "/dev/mapper/$NEW_MAPPER" ] || die "the running root is $src, not /dev/mapper/$NEW_MAPPER"
  POOL_DEV=$src
  POOL_PART=$(lsblk -nrps -o NAME "$POOL_DEV" | sed -n 2p)
  POOL_DISK=$(disk_of "$POOL_PART")
  [ "$POOL_DISK" = "$(readlink -f "$TARGET")" ] || die "the pool is on $POOL_DISK, not on $TARGET"
}

pool_devices() { btrfs filesystem show / | awk '/devid/ { print $NF }'; }

phase_extend_prepare() {
  need_root
  find_pool
  [ -b "$SECOND" ] || die "the second disk $SECOND is not here"
  local disk
  disk=$(readlink -f "$SECOND")
  [ "$disk" != "$POOL_DISK" ] || die "$SECOND is the pool's own disk"
  [ "$(pool_devices | wc -l)" = 1 ] || die "the pool has more than one device already: $(pool_devices | xargs)"
  if lsblk -nrpo MOUNTPOINTS "$disk" | grep -q .; then
    die "something on $disk is mounted; unmount it first:
$(lsblk -o NAME,MOUNTPOINTS "$disk")"
  fi
  if lsblk -nrpo TYPE "$disk" | grep -qx crypt; then
    die "a LUKS container on $disk is open (file manager?); close it first"
  fi
  done_p extend-prepare && die "'extend-prepare' ran already; next is the reboot, then 'extend'"

  say "Second pool member: $disk ($(lsblk -dno MODEL,SERIAL,SIZE "$disk" | xargs))"
  lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL "$disk"
  ensure_key
  if [ "$DRY" = 0 ]; then
    cryptsetup open --test-passphrase --key-file "$KEY_FILE" "$POOL_PART" 2>/dev/null ||
      die "the passphrase is not the pool's: boot would ask twice; use the pool's passphrase"
  fi
  confirm EXTEND "ERASE $disk (the old M90aPro system) and make it one LUKS partition '$POOL2_LABEL' for the pool."
  local part
  while read -r part; do
    [ "$part" = "$disk" ] || run wipefs -a "$part"
  done < <(lsblk -nrpo NAME "$disk")
  run wipefs -a "$disk"
  run sgdisk --zap-all "$disk"
  run sgdisk -n1:0:0 -t1:8309 -c1:"$POOL2_LABEL" "$disk"
  run blockdev --rereadpt "$disk" || true
  run udevadm settle
  local p2="/dev/disk/by-partlabel/$POOL2_LABEL"
  if [ "$DRY" = 0 ]; then
    [ "$(disk_of "$p2")" = "$disk" ] || die "$p2 is not on $disk"
  fi
  # shellcheck disable=SC2086  # M90_LUKS_ARGS is a list of options
  run cryptsetup luksFormat --batch-mode --type luks2 ${M90_LUKS_ARGS:-} --key-file "$KEY_FILE" "$p2"
  mark extend-prepare
  say "Done.  Now: set custom.m90Pool.secondDisk = true (hosts/M90aPro/layouts.nix), commit,"
  say "  sudo nixos-rebuild boot --flake ~/Projects/NixOS#M90aPro,  reboot,  then: sudo m90-btrfs-migrate extend"
}

phase_extend() {
  need_root
  find_pool
  local dev=/dev/mapper/$SECOND_MAPPER
  if pool_devices | grep -qx "$dev"; then
    say "$dev is in the pool already."
    btrfs filesystem usage -T / | head -20 || true
    return 0
  fi
  [ -e /etc/m90-pool/second-disk ] ||
    die "the running system does not unlock the second disk at boot: set custom.m90Pool.secondDisk, nixos-rebuild boot, reboot"
  [ -e /nix/var/nix/profiles/system/etc/m90-pool/second-disk ] ||
    die "the default boot entry would not unlock the second disk: nixos-rebuild boot with custom.m90Pool.secondDisk"
  [ -e "$dev" ] || die "$dev is not open: was the second disk unlocked at boot?"
  [ "$(lsblk -nrps -o NAME "$dev" | sed -n 2p)" = "$(readlink -f "/dev/disk/by-partlabel/$POOL2_LABEL")" ] ||
    die "$dev is not the partition $POOL2_LABEL"
  [ -z "$(blkid -p -s TYPE -o value "$dev" 2>/dev/null || true)" ] || die "$dev holds a filesystem already"
  [ "$(pool_devices | wc -l)" = 1 ] || die "the pool has an unexpected device: $(pool_devices | xargs)"
  confirm ADD "Add $dev ($(lsblk -dno SIZE "$dev" | xargs)) to the btrfs pool: data single, metadata raid1."
  run btrfs device add "$dev" /
  # Metadata (and with it the system chunks) mirrored; data stays single, and
  # new data goes to whichever device has more room.
  run btrfs balance start -mconvert=raid1 /
  mark extend
  btrfs filesystem usage -T / | head -20 || true
  say "The pool spans both SSDs."
}

phase_umount() {
  need_root
  local m running
  for m in $(findmnt -rno TARGET | grep "^$MNT" | sort -r); do umount "$m" || umount -l "$m"; done
  running=$(findmnt -no SOURCE / | sed 's/\[.*//')
  for m in "$OLD_MAPPER" "$NEW_MAPPER"; do
    [ -e "/dev/mapper/$m" ] || continue
    [ "/dev/mapper/$m" = "$running" ] && continue
    cryptsetup close "$m"
  done
  say "Unmounted $MNT and closed $OLD_MAPPER / $NEW_MAPPER."
}

case "$PHASE" in
  prepare) phase_prepare ;;
  check) phase_check ;;
  format) phase_format ;;
  copy) phase_copy ;;
  install) phase_install ;;
  extend-prepare) phase_extend_prepare ;;
  extend) phase_extend ;;
  umount) phase_umount ;;
  *) usage; exit 2 ;;
esac
