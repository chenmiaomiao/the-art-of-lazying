#!/bin/bash

set -euo pipefail

readonly EXPECTED_VOLUME_NAME="MACRECOVERY"
readonly EXPECTED_CONFIRMATION="PROMOTE-3040-INSTALLED-EFI"
readonly MINIMUM_ESP_BYTES=4200000000
readonly MAXIMUM_ESP_BYTES=4400000000
readonly MINIMUM_DISK_BYTES=900000000000
readonly MAXIMUM_DISK_BYTES=1100000000000

mode="${1:-audit}"
device=""
candidate=""
manifest=""
ocvalidate=""
confirmation=""

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

plist_value() {
  local plist="$1"
  local key="$2"

  /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null
}

verify_manifest() {
  local root="$1"
  local list="$2"

  (
    cd "$root"
    shasum -a 256 -c "$list"
  )
}

shift || true
while [ "$#" -gt 0 ]; do
  case "$1" in
    --device)
      [ "$#" -ge 2 ] || fail "--device requires diskXsY"
      device="$2"
      shift 2
      ;;
    --candidate)
      [ "$#" -ge 2 ] || fail "--candidate requires a directory"
      candidate="$2"
      shift 2
      ;;
    --manifest)
      [ "$#" -ge 2 ] || fail "--manifest requires a file"
      manifest="$2"
      shift 2
      ;;
    --ocvalidate)
      [ "$#" -ge 2 ] || fail "--ocvalidate requires a file"
      ocvalidate="$2"
      shift 2
      ;;
    --confirm)
      [ "$#" -ge 2 ] || fail "--confirm requires a token"
      confirmation="$2"
      shift 2
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || fail "run this script on macOS"
case "$mode" in
  audit|apply) ;;
  *) fail "mode must be audit or apply" ;;
esac
case "$device" in
  disk[0-9]*s[0-9]*) ;;
  *) fail "pass the exact MACRECOVERY partition as --device diskXsY" ;;
esac

partition_plist=$(mktemp "${TMPDIR:-/tmp}/3040-partition.XXXXXX")
whole_plist=$(mktemp "${TMPDIR:-/tmp}/3040-whole-disk.XXXXXX")
diskutil info -plist "/dev/$device" > "$partition_plist"
whole_disk=$(plist_value "$partition_plist" ParentWholeDisk)
[ -n "$whole_disk" ] || fail "could not identify the parent disk"
diskutil info -plist "/dev/$whole_disk" > "$whole_plist"

volume_name=$(plist_value "$partition_plist" VolumeName)
partition_type=$(plist_value "$partition_plist" Content)
partition_size=$(plist_value "$partition_plist" TotalSize)
internal=$(plist_value "$partition_plist" Internal)
whole_size=$(plist_value "$whole_plist" TotalSize)
whole_model=$(plist_value "$whole_plist" MediaName)

[ "$volume_name" = "$EXPECTED_VOLUME_NAME" ] ||
  fail "unexpected volume name on $device: $volume_name"
[ "$partition_type" = "EFI" ] ||
  fail "unexpected partition type on $device: $partition_type"
[ "$internal" = "true" ] ||
  fail "$device is not reported as an internal partition"
case "$partition_size" in
  ''|*[!0-9]*) fail "invalid MACRECOVERY size: $partition_size" ;;
esac
if [ "$partition_size" -lt "$MINIMUM_ESP_BYTES" ] ||
   [ "$partition_size" -gt "$MAXIMUM_ESP_BYTES" ]; then
  fail "MACRECOVERY is not the audited 4 GiB ESP"
fi
case "$whole_size" in
  ''|*[!0-9]*) fail "invalid parent disk size: $whole_size" ;;
esac
if [ "$whole_size" -lt "$MINIMUM_DISK_BYTES" ] ||
   [ "$whole_size" -gt "$MAXIMUM_DISK_BYTES" ]; then
  fail "MACRECOVERY is not on the audited 1 TB disk"
fi
case "$whole_model" in
  *TOSHIBA*|*Toshiba*) ;;
  *) fail "MACRECOVERY parent is not the audited Toshiba disk: $whole_model" ;;
esac

sudo diskutil mount "$device" >/dev/null
diskutil info -plist "/dev/$device" > "$partition_plist"
mount_point=$(plist_value "$partition_plist" MountPoint)
[ -d "$mount_point/EFI/OC" ] ||
  fail "live OpenCore EFI is missing from $mount_point"
[ -f "$mount_point/EFI/OC/config.plist" ] ||
  fail "live OpenCore config is missing"

printf 'Validated device: /dev/%s\n' "$device"
printf 'Parent: %s, %s bytes, %s\n' "$whole_disk" "$whole_size" "$whole_model"
printf 'Mounted at: %s\n' "$mount_point"
printf 'Live OpenCore files: %s\n' \
  "$(find "$mount_point/EFI" -type f | wc -l | tr -d ' ')"

if [ "$mode" = "audit" ]; then
  printf 'Audit complete. No EFI file or firmware variable was changed.\n'
  exit 0
fi

[ "$confirmation" = "$EXPECTED_CONFIRMATION" ] ||
  fail "apply requires --confirm $EXPECTED_CONFIRMATION"
if [ ! -d "$candidate/BOOT" ] || [ ! -d "$candidate/OC" ]; then
  fail "candidate must contain BOOT and OC directories"
fi
[ -f "$candidate/OC/config.plist" ] ||
  fail "candidate config is missing"
[ -f "$manifest" ] || fail "candidate manifest is missing"
[ -x "$ocvalidate" ] || fail "matching ocvalidate executable is missing"

CDPATH=''
candidate=$(cd -- "$candidate" && pwd)
manifest=$(
  cd -- "$(dirname -- "$manifest")" &&
    printf '%s/%s\n' "$PWD" "$(basename -- "$manifest")"
)
ocvalidate=$(
  cd -- "$(dirname -- "$ocvalidate")" &&
    printf '%s/%s\n' "$PWD" "$(basename -- "$ocvalidate")"
)

verify_manifest "$candidate" "$manifest"
"$ocvalidate" "$candidate/OC/config.plist"

show_picker=$(
  /usr/libexec/PlistBuddy \
    -c "Print :Misc:Boot:ShowPicker" \
    "$candidate/OC/config.plist"
)
timeout=$(
  /usr/libexec/PlistBuddy \
    -c "Print :Misc:Boot:Timeout" \
    "$candidate/OC/config.plist"
)
if [ "$show_picker" != "true" ] || [ "$timeout" != "8" ]; then
  fail "candidate is not the reviewed installed-system picker profile"
fi
grep -Fq "OpenLegacyBoot.efi" "$manifest" ||
  fail "candidate manifest does not contain OpenLegacyBoot.efi"
grep -Fq "OpenNtfsDxe.efi" "$manifest" ||
  fail "candidate manifest does not contain OpenNtfsDxe.efi"

timestamp=$(date -u '+%Y%m%dT%H%M%SZ')
backup_root="$HOME/Documents/OptiPlex-3040-EFI-Backups/$timestamp"
mkdir -p "$backup_root"
ditto "$mount_point/EFI" "$backup_root/EFI"
sudo nvram -xp | tee "$backup_root/nvram-before.xml" >/dev/null
(
  cd "$backup_root/EFI"
  find . -type f -print |
    LC_ALL=C sort |
    while IFS= read -r path; do
      shasum -a 256 "$path"
    done
) > "$backup_root/EFI.SHA256SUMS"

stage="$mount_point/.EFI.installed-candidate.$timestamp"
rollback="$mount_point/EFI.rollback.$timestamp"
failed="$mount_point/EFI.failed.$timestamp"
if [ -e "$stage" ] || [ -e "$rollback" ] || [ -e "$failed" ]; then
  fail "unexpected pre-existing transaction path"
fi
ditto "$candidate" "$stage"
verify_manifest "$stage" "$manifest"
sync

mv "$mount_point/EFI" "$rollback"
if ! mv "$stage" "$mount_point/EFI"; then
  mv "$rollback" "$mount_point/EFI"
  fail "candidate rename failed; restored the prior EFI"
fi
sync

if ! verify_manifest "$mount_point/EFI" "$manifest"; then
  mv "$mount_point/EFI" "$failed"
  mv "$rollback" "$mount_point/EFI"
  sync
  fail "post-promotion verification failed; restored the prior EFI"
fi

printf 'Installed candidate promoted without changing firmware order.\n'
printf 'Rollback EFI: %s\n' "$rollback"
printf 'Independent backup: %s\n' "$backup_root"
printf 'Next step: use Dell one-time boot and physically test every picker entry.\n'
