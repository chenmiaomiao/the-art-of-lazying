#!/bin/bash

set -euo pipefail

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

readonly DEFAULT_LABEL="Monterey"

usage() {
  cat <<'EOF'
Usage:
  fix-opencore-macos-label-from-recovery.sh VOLUME_GROUP_UUID [LABEL]

Run from macOS Recovery Terminal. The script mounts APFS Preboot volumes,
finds only the audited volume-group directory, backs up its current OpenCore
label files, and regenerates the label with bless.

Find the UUID before rebooting with:
  diskutil apfs listVolumeGroups
EOF
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

[ -x /usr/sbin/diskutil ] || fail "diskutil is unavailable; run from macOS Recovery"
[ -x /usr/sbin/bless ] || fail "bless is unavailable; run from macOS Recovery"
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  usage
  exit 2
fi

volume_group_uuid=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
label=${2:-$DEFAULT_LABEL}

case "$volume_group_uuid" in
  ????????-????-????-????-????????????) ;;
  *) fail "invalid APFS volume-group UUID: $volume_group_uuid" ;;
esac

[ -n "$label" ] || fail "label must not be empty"

preboot_devices=$(
  diskutil apfs list |
    awk '
      /APFS Volume Disk \(Role\):/ && /\(Preboot\)/ {
        for (field = 2; field <= NF; field++) {
          if ($field == "(Preboot)") {
            print $(field - 1)
          }
        }
      }
    '
)
[ -n "$preboot_devices" ] || fail "no APFS Preboot volume was found"

target=""
for device in $preboot_devices; do
  case "$device" in
    disk[0-9]*s[0-9]*) ;;
    *) fail "invalid Preboot device parsed from diskutil: $device" ;;
  esac
  printf 'Discovered Preboot device: %s\n' "$device"
  diskutil mount "$device" >/dev/null ||
    fail "could not mount Preboot device $device"
  mount_point=$(
    diskutil info "$device" |
      sed -n 's/^[[:space:]]*Mount Point:[[:space:]]*//p' |
      head -n 1
  )
  [ -n "$mount_point" ] ||
    fail "diskutil did not report a mount point for $device"
  [ "$mount_point" != "Not Mounted" ] ||
    fail "Preboot device $device remained unmounted"
  [ -d "$mount_point" ] ||
    fail "reported Preboot mount point does not exist: $mount_point"
  printf 'Mounted Preboot at: %s\n' "$mount_point"

  candidate="$mount_point/$volume_group_uuid/System/Library/CoreServices"
  if [ -f "$candidate/boot.efi" ]; then
    [ -z "$target" ] ||
      fail "volume-group UUID appears on more than one Preboot volume"
    target=$candidate
  fi
done

[ -n "$target" ] ||
  fail "could not find boot.efi for volume group $volume_group_uuid"

backup="$target/.codex-label-backup-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$backup"
for name in \
  .contentDetails \
  .disk_label \
  .disk_label_2x \
  .disk_label.contentDetails; do
  [ ! -e "$target/$name" ] || cp -p "$target/$name" "$backup/$name"
done

bless --folder "$target" --label "$label"
printf '%s' "$label" >"$target/.contentDetails"
printf '%s' "$label" >"$target/.disk_label.contentDetails"

actual=$(cat "$target/.disk_label.contentDetails")
[ "$actual" = "$label" ] ||
  fail "label verification failed: expected '$label', got '$actual'"

printf 'Updated OpenCore label: %s\n' "$label"
printf 'Target: %s\n' "$target"
printf 'Backup: %s\n' "$backup"
