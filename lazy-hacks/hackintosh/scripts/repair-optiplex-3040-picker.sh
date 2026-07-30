#!/bin/bash

set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

readonly CONFIRMATION="REPAIR-3040-PICKER"
readonly WIN10_VOLUME_NAME="WIN10 EFI"
readonly OPENCORE_VOLUME_NAME="MACRECOVERY"
readonly WIN10_MIN_BYTES=100000000
readonly WIN10_MAX_BYTES=110000000
readonly OPENCORE_MIN_BYTES=4200000000
readonly OPENCORE_MAX_BYTES=4400000000

mode="${1:-audit}"
win10_device=""
opencore_device=""
ocvalidate=""
confirmation=""
win10_whole_disk=""
win10_mount_point=""
win10_parent_model=""
opencore_whole_disk=""
opencore_mount_point=""
opencore_parent_model=""

usage() {
  cat <<'EOF'
Usage:
  repair-optiplex-3040-picker.sh audit \
    --win10-device diskXsY \
    --opencore-device diskXsY \
    --ocvalidate /path/to/OpenCore-1.0.7/Utilities/ocvalidate/ocvalidate

  repair-optiplex-3040-picker.sh apply \
    --win10-device diskXsY \
    --opencore-device diskXsY \
    --ocvalidate /path/to/OpenCore-1.0.7/Utilities/ocvalidate/ocvalidate \
    --confirm REPAIR-3040-PICKER

The guarded repair exposes the primary Windows Boot Manager, hides only its
byte-identical fallback copy, and disables OpenLegacyBoot when the former
Windows 7 disk is now pure GPT with only a protective MBR. It does not edit
the BCD, partition table, firmware boot order, or saved OpenCore default.
EOF
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

plist_value() {
  local plist="$1"
  local key="$2"

  /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null
}

absolute_path() {
  local path="$1"

  (
    cd -- "$(dirname -- "$path")"
    printf '%s/%s\n' "$PWD" "$(basename -- "$path")"
  )
}

assert_integer_between() {
  local value="$1"
  local minimum="$2"
  local maximum="$3"
  local label="$4"

  case "$value" in
    ''|*[!0-9]*) fail "$label is not an integer: $value" ;;
  esac
  if [ "$value" -lt "$minimum" ] || [ "$value" -gt "$maximum" ]; then
    fail "$label is outside the audited range: $value"
  fi
}

inspect_partition() {
  local device="$1"
  local expected_name="$2"
  local minimum_size="$3"
  local maximum_size="$4"
  local expected_parent_model="$5"
  local prefix="$6"
  local partition_plist
  local whole_plist
  local whole_disk
  local volume_name
  local content
  local total_size
  local internal
  local mount_point
  local parent_model
  local parent_model_lower
  local expected_parent_model_lower

  partition_plist=$(mktemp "${TMPDIR:-/tmp}/3040-partition.XXXXXX")
  whole_plist=$(mktemp "${TMPDIR:-/tmp}/3040-whole.XXXXXX")
  diskutil info -plist "/dev/$device" > "$partition_plist"
  whole_disk=$(plist_value "$partition_plist" ParentWholeDisk)
  [ -n "$whole_disk" ] || fail "could not determine the parent of $device"
  diskutil info -plist "/dev/$whole_disk" > "$whole_plist"

  volume_name=$(plist_value "$partition_plist" VolumeName)
  content=$(plist_value "$partition_plist" Content)
  total_size=$(plist_value "$partition_plist" TotalSize)
  internal=$(plist_value "$partition_plist" Internal)
  mount_point=$(plist_value "$partition_plist" MountPoint)
  parent_model=$(plist_value "$whole_plist" MediaName)
  parent_model_lower=$(printf '%s' "$parent_model" | tr '[:upper:]' '[:lower:]')
  expected_parent_model_lower=$(
    printf '%s' "$expected_parent_model" | tr '[:upper:]' '[:lower:]'
  )

  [ "$volume_name" = "$expected_name" ] ||
    fail "$device has unexpected volume name: $volume_name"
  [ "$content" = "EFI" ] ||
    fail "$device is not an EFI System Partition: $content"
  [ "$internal" = "true" ] || fail "$device is not internal"
  assert_integer_between \
    "$total_size" "$minimum_size" "$maximum_size" "$device size"
  case "$parent_model_lower" in
    *"$expected_parent_model_lower"*) ;;
    *) fail "$device has unexpected parent model: $parent_model" ;;
  esac
  [ -n "$mount_point" ] || fail "$device did not mount"

  eval "${prefix}_whole_disk=\$whole_disk"
  eval "${prefix}_mount_point=\$mount_point"
  eval "${prefix}_parent_model=\$parent_model"
  rm -f "$partition_plist" "$whole_plist"
}

find_legacy_driver_index() {
  local config="$1"
  local index=0
  local path

  while path=$(
    /usr/libexec/PlistBuddy \
      -c "Print :UEFI:Drivers:$index:Path" \
      "$config" \
      2>/dev/null
  ); do
    if [ "$path" = "OpenLegacyBoot.efi" ]; then
      printf '%s\n' "$index"
      return 0
    fi
    index=$((index + 1))
  done
  return 1
}

marker_state() {
  local marker="$1"

  if [ ! -e "$marker" ]; then
    printf 'missing\n'
  elif [ -f "$marker" ] && [ "$(cat "$marker")" = "Disabled" ]; then
    printf 'disabled\n'
  else
    printf 'invalid\n'
  fi
}

case "$mode" in
  -h|--help)
    usage
    exit 0
    ;;
esac

shift || true
while [ "$#" -gt 0 ]; do
  case "$1" in
    --win10-device)
      [ "$#" -ge 2 ] || fail "--win10-device requires diskXsY"
      win10_device="$2"
      shift 2
      ;;
    --opencore-device)
      [ "$#" -ge 2 ] || fail "--opencore-device requires diskXsY"
      opencore_device="$2"
      shift 2
      ;;
    --ocvalidate)
      [ "$#" -ge 2 ] || fail "--ocvalidate requires a path"
      ocvalidate="$2"
      shift 2
      ;;
    --confirm)
      [ "$#" -ge 2 ] || fail "--confirm requires a token"
      confirmation="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || fail "run this script on macOS"
[ "$(id -u)" -ne 0 ] || fail "run as the logged-in user, not root"
case "$mode" in
  audit|apply) ;;
  *) fail "mode must be audit or apply" ;;
esac
case "$win10_device" in
  disk[0-9]*s[0-9]*) ;;
  *) fail "pass the exact Windows ESP as --win10-device diskXsY" ;;
esac
case "$opencore_device" in
  disk[0-9]*s[0-9]*) ;;
  *) fail "pass the exact OpenCore ESP as --opencore-device diskXsY" ;;
esac
[ -x "$ocvalidate" ] || fail "matching OpenCore 1.0.7 ocvalidate is missing"
ocvalidate=$(absolute_path "$ocvalidate")

printf 'Administrator access is required for read-only partition evidence.\n'
sudo -v
sudo diskutil mount readOnly "$win10_device" >/dev/null
sudo diskutil mount readOnly "$opencore_device" >/dev/null

inspect_partition \
  "$win10_device" \
  "$WIN10_VOLUME_NAME" \
  "$WIN10_MIN_BYTES" \
  "$WIN10_MAX_BYTES" \
  "samsung" \
  win10
inspect_partition \
  "$opencore_device" \
  "$OPENCORE_VOLUME_NAME" \
  "$OPENCORE_MIN_BYTES" \
  "$OPENCORE_MAX_BYTES" \
  "toshiba" \
  opencore

primary_dir="$win10_mount_point/EFI/Microsoft/Boot"
fallback_dir="$win10_mount_point/EFI/Boot"
primary_loader="$primary_dir/bootmgfw.efi"
fallback_loader="$fallback_dir/bootx64.efi"
bcd="$primary_dir/BCD"
primary_marker="$primary_dir/.contentVisibility"
fallback_marker="$fallback_dir/.contentVisibility"
config="$opencore_mount_point/EFI/OC/config.plist"

[ -f "$primary_loader" ] || fail "primary Windows loader is missing"
[ -f "$fallback_loader" ] || fail "fallback Windows loader is missing"
[ -f "$bcd" ] || fail "Windows BCD is missing"
[ -f "$config" ] || fail "OpenCore config is missing"
cmp -s "$primary_loader" "$fallback_loader" ||
  fail "primary and fallback Windows loaders are not byte-identical"
/usr/bin/file "$primary_loader" | grep -Fq "EFI application" ||
  fail "primary Windows loader is not an x86-64 EFI application"
/usr/bin/file "$bcd" | grep -Fq "MS Windows registry file" ||
  fail "Windows BCD is not a readable registry hive"
"$ocvalidate" "$config"

legacy_index=$(find_legacy_driver_index "$config") ||
  fail "OpenLegacyBoot.efi is not present in the OpenCore driver list"
legacy_enabled=$(
  /usr/libexec/PlistBuddy \
    -c "Print :UEFI:Drivers:$legacy_index:Enabled" \
    "$config"
)
primary_state=$(marker_state "$primary_marker")
fallback_state=$(marker_state "$fallback_marker")
[ "$primary_state" != "invalid" ] ||
  fail "primary .contentVisibility has unsupported contents"
[ "$fallback_state" != "invalid" ] ||
  fail "fallback .contentVisibility has unsupported contents"

whole_audit_plist=$(mktemp "${TMPDIR:-/tmp}/3040-whole-audit.XXXXXX")
diskutil info -plist "/dev/$opencore_whole_disk" > "$whole_audit_plist"
disk_content=$(plist_value "$whole_audit_plist" Content)
rm -f "$whole_audit_plist"
[ "$disk_content" = "GUID_partition_scheme" ] ||
  fail "$opencore_whole_disk is not GPT"
mbr_report=$(sudo fdisk "/dev/$opencore_whole_disk")
printf '%s\n' "$mbr_report" |
  awk '$1 == "1:" && $2 == "EE" { found = 1 } END { exit !found }' ||
  fail "$opencore_whole_disk does not have a protective GPT MBR"
if printf '%s\n' "$mbr_report" |
   awk '$1 ~ /^[234]:$/ && $2 != "00" { found = 1 } END { exit !found }'; then
  fail "$opencore_whole_disk has a hybrid MBR; do not use this repair"
fi

printf '\n=== audited state ===\n'
printf 'Windows ESP: /dev/%s on %s (%s)\n' \
  "$win10_device" "$win10_whole_disk" "$win10_parent_model"
printf 'OpenCore ESP: /dev/%s on %s (%s)\n' \
  "$opencore_device" "$opencore_whole_disk" "$opencore_parent_model"
printf 'Windows loader SHA-256: %s\n' \
  "$(shasum -a 256 "$primary_loader" | awk '{ print $1 }')"
printf 'Primary marker: %s\n' "$primary_state"
printf 'Fallback marker: %s\n' "$fallback_state"
printf 'OpenLegacyBoot enabled: %s\n' "$legacy_enabled"
printf 'Windows 7 parent layout: pure GPT with protective MBR\n'

desired=0
if [ "$primary_state" = "missing" ] &&
   [ "$fallback_state" = "disabled" ] &&
   [ "$legacy_enabled" = "false" ]; then
  desired=1
fi
repairable=0
if [ "$primary_state" = "disabled" ] &&
   [ "$fallback_state" = "missing" ] &&
   [ "$legacy_enabled" = "true" ]; then
  repairable=1
fi

if [ "$mode" = "audit" ]; then
  if [ "$desired" -eq 1 ]; then
    printf 'Result: repaired state is present.\n'
  elif [ "$repairable" -eq 1 ]; then
    printf 'Result: known pre-repair state is present; apply is available.\n'
  else
    fail "state is neither the reviewed pre-repair nor post-repair layout"
  fi
  printf 'No EFI file, BCD, partition table, or firmware variable was changed.\n'
  exit 0
fi

[ "$confirmation" = "$CONFIRMATION" ] ||
  fail "apply requires --confirm $CONFIRMATION"
if [ "$desired" -eq 1 ]; then
  printf 'Repair is already applied; no file was changed.\n'
  exit 0
fi
[ "$repairable" -eq 1 ] ||
  fail "refusing to apply from an unreviewed state"

timestamp=$(date -u '+%Y%m%dT%H%M%SZ')
backup_root="$HOME/Documents/OptiPlex-3040-Boot-Backups/$timestamp"
mkdir -p "$backup_root/WIN10-EFI" "$backup_root/MACRECOVERY-EFI"
ditto "$win10_mount_point/EFI" "$backup_root/WIN10-EFI"
ditto "$opencore_mount_point/EFI" "$backup_root/MACRECOVERY-EFI"
sudo nvram -xp | tee "$backup_root/nvram-before.xml" >/dev/null
diskutil list > "$backup_root/diskutil-list.txt"
sudo gpt -r show "/dev/$opencore_whole_disk" \
  | tee "$backup_root/${opencore_whole_disk}-gpt.txt" >/dev/null
printf '%s\n' "$mbr_report" \
  > "$backup_root/${opencore_whole_disk}-mbr.txt"
(
  cd "$backup_root"
  find . -type f ! -name SHA256SUMS -print |
    LC_ALL=C sort |
    while IFS= read -r path; do
      shasum -a 256 "$path"
    done
) > "$backup_root/SHA256SUMS"
(
  cd "$backup_root"
  shasum -a 256 -c SHA256SUMS
)

candidate=$(mktemp "${TMPDIR:-/tmp}/3040-config.XXXXXX")
cp "$config" "$candidate"
/usr/libexec/PlistBuddy \
  -c "Set :UEFI:Drivers:$legacy_index:Enabled false" \
  "$candidate"
plutil -lint "$candidate"
"$ocvalidate" "$candidate"

rollback_required=1
rollback() {
  status=$?
  trap - EXIT HUP INT TERM
  if [ "$status" -ne 0 ] && [ "$rollback_required" -eq 1 ]; then
    printf 'Repair failed; restoring both reviewed EFI changes.\n' >&2
    sudo mount -uw "$win10_mount_point" 2>/dev/null || true
    sudo mount -uw "$opencore_mount_point" 2>/dev/null || true
    sudo rm -f "$primary_marker" "$fallback_marker"
    sudo cp \
      "$backup_root/WIN10-EFI/Microsoft/Boot/.contentVisibility" \
      "$primary_marker"
    sudo cp \
      "$backup_root/MACRECOVERY-EFI/OC/config.plist" \
      "$config"
    sudo rm -f \
      "$opencore_mount_point/EFI/OC/.config.plist.picker-repair.$$"
    sync
    sudo mount -ur "$win10_mount_point" 2>/dev/null || true
    sudo mount -ur "$opencore_mount_point" 2>/dev/null || true
  fi
  rm -f "$candidate"
  exit "$status"
}
trap rollback EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

sudo mount -uw "$win10_mount_point"
sudo mount -uw "$opencore_mount_point"
sudo mv "$primary_marker" "$fallback_marker"
config_stage="$opencore_mount_point/EFI/OC/.config.plist.picker-repair.$$"
sudo cp "$candidate" "$config_stage"
sudo mv -f "$config_stage" "$config"
sync

[ ! -e "$primary_marker" ] ||
  fail "primary visibility marker still exists after repair"
[ "$(cat "$fallback_marker")" = "Disabled" ] ||
  fail "fallback visibility marker did not verify"
[ "$(
  /usr/libexec/PlistBuddy \
    -c "Print :UEFI:Drivers:$legacy_index:Enabled" \
    "$config"
)" = "false" ] || fail "OpenLegacyBoot was not disabled"
"$ocvalidate" "$config"
cmp -s "$primary_loader" "$fallback_loader" ||
  fail "Windows loaders changed during the metadata repair"

sudo mount -ur "$win10_mount_point"
sudo mount -ur "$opencore_mount_point"
rollback_required=0
rm -f "$candidate"
trap - EXIT HUP INT TERM

printf '\nRepair applied and verified.\n'
printf 'Backup: %s\n' "$backup_root"
printf 'Monterey remains the saved default; firmware variables were not edited.\n'
printf 'Next gate: physically test Monterey, then the single Windows 10 entry.\n'
printf 'Windows 7 remains hidden until it is rebuilt as a UEFI boot path.\n'
