#!/bin/bash

set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
export LC_ALL=C
export LANG=C

readonly ARM_CONFIRMATION="ARM-3040-NATIVE-PICKER"
readonly DISARM_CONFIRMATION="DISARM-3040-NATIVE-PICKER"
readonly SOURCE_VOLUME_NAME="MACRECOVERY"
readonly TARGET_VOLUME_NAME="WIN10 EFI"
readonly SOURCE_MIN_BYTES=4200000000
readonly SOURCE_MAX_BYTES=4400000000
readonly TARGET_MIN_BYTES=100000000
readonly TARGET_MAX_BYTES=110000000
readonly ENTRY_NAME="Monterey Native Graphics Test"
readonly ENTRY_COMMENT="Isolated native Skylake HD 530 validation loader"
readonly CANDIDATE_MARKER=".optiplex-3040-monterey-native"

mode="${1:-audit}"
source_device=""
target_device=""
ocvalidate=""
confirmation=""
source_mount_point=""
target_mount_point=""
target_partition_uuid=""
entry_path=""

usage() {
  cat <<'EOF'
Usage:
  arm-optiplex-3040-monterey-native-picker.sh audit \
    --source-device diskXsY \
    --target-device diskXs1 \
    --ocvalidate /path/to/OpenCore-1.0.7/ocvalidate

  arm-optiplex-3040-monterey-native-picker.sh arm \
    --source-device diskXsY \
    --target-device diskXs1 \
    --ocvalidate /path/to/OpenCore-1.0.7/ocvalidate \
    --confirm ARM-3040-NATIVE-PICKER

  arm-optiplex-3040-monterey-native-picker.sh disarm \
    --source-device diskXsY \
    --target-device diskXs1 \
    --ocvalidate /path/to/OpenCore-1.0.7/ocvalidate \
    --confirm DISARM-3040-NATIVE-PICKER

This machine-specific script exposes the separately staged native-HD-530
OpenCore candidate as an explicit, non-default picker entry. It never edits
the candidate, Windows loaders, BCD, partition tables, firmware boot order,
or the saved default operating system.
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

mount_read_only() {
  local device="$1"
  local attempt=0

  sudo diskutil unmount "$device" >/dev/null 2>&1 || true
  sudo diskutil mount readOnly "$device" >/dev/null
  while [ "$attempt" -lt 20 ]; do
    if mount |
      awk -v device="/dev/$device" '
        $1 == device && index($0, "read-only") {
          found = 1
        }
        END {
          exit !found
        }
      '; then
      return 0
    fi
    sleep 0.25
    attempt=$((attempt + 1))
  done
  return 1
}

mount_read_write() {
  local device="$1"
  local attempt=0

  sudo diskutil unmount "$device" >/dev/null 2>&1 || true
  sudo diskutil mount "$device" >/dev/null
  while [ "$attempt" -lt 20 ]; do
    if mount |
      awk -v device="/dev/$device" '
        $1 == device && !index($0, "read-only") {
          found = 1
        }
        END {
          exit !found
        }
      '; then
      return 0
    fi
    sleep 0.25
    attempt=$((attempt + 1))
  done
  return 1
}

inspect_partition() {
  local device="$1"
  local expected_name="$2"
  local minimum_size="$3"
  local maximum_size="$4"
  local expected_model="$5"
  local mount_output_variable="$6"
  local uuid_output_variable="$7"
  local partition_plist
  local whole_plist
  local whole_disk
  local volume_name
  local content
  local total_size
  local internal
  local mount_point
  local parent_model
  local partition_uuid

  partition_plist=$(mktemp "${TMPDIR:-/tmp}/3040-picker-partition.XXXXXX")
  whole_plist=$(mktemp "${TMPDIR:-/tmp}/3040-picker-whole.XXXXXX")
  diskutil info -plist "/dev/$device" > "$partition_plist"
  whole_disk=$(plist_value "$partition_plist" ParentWholeDisk)
  [ -n "$whole_disk" ] || fail "could not determine parent disk for $device"
  diskutil info -plist "/dev/$whole_disk" > "$whole_plist"

  volume_name=$(plist_value "$partition_plist" VolumeName)
  content=$(plist_value "$partition_plist" Content)
  total_size=$(plist_value "$partition_plist" TotalSize)
  internal=$(plist_value "$partition_plist" Internal)
  mount_point=$(plist_value "$partition_plist" MountPoint)
  partition_uuid=$(plist_value "$partition_plist" DiskUUID)
  parent_model=$(plist_value "$whole_plist" MediaName)

  [ "$volume_name" = "$expected_name" ] ||
    fail "$device has unexpected volume name: $volume_name"
  [ "$content" = "EFI" ] ||
    fail "$device is not an EFI System Partition: $content"
  [ "$internal" = "true" ] || fail "$device is not internal"
  [ -n "$mount_point" ] || fail "$device did not mount"
  assert_integer_between \
    "$total_size" "$minimum_size" "$maximum_size" "$device size"
  printf '%s' "$parent_model" |
    tr '[:upper:]' '[:lower:]' |
    grep -Fq "$expected_model" ||
    fail "$device has unexpected parent model: $parent_model"
  [ -n "$partition_uuid" ] ||
    fail "$device has no GPT partition UUID"

  eval "$mount_output_variable=\$mount_point"
  if [ -n "$uuid_output_variable" ]; then
    eval "$uuid_output_variable=\$partition_uuid"
  fi
  rm -f "$partition_plist" "$whole_plist"
}

verify_test_entry() {
  local config="$1"

  [ "$(plist_value "$config" "Misc:Entries:0:Arguments")" = "" ] ||
    fail "test picker entry has unexpected arguments"
  [ "$(plist_value "$config" "Misc:Entries:0:Auxiliary")" = "false" ] ||
    fail "test picker entry is unexpectedly auxiliary"
  [ "$(plist_value "$config" "Misc:Entries:0:Comment")" = "$ENTRY_COMMENT" ] ||
    fail "test picker entry has an unexpected comment"
  [ "$(plist_value "$config" "Misc:Entries:0:Enabled")" = "true" ] ||
    fail "test picker entry is disabled"
  [ "$(plist_value "$config" "Misc:Entries:0:Flavour")" = "Auto" ] ||
    fail "test picker entry has an unexpected flavour"
  [ "$(plist_value "$config" "Misc:Entries:0:Name")" = "$ENTRY_NAME" ] ||
    fail "test picker entry has an unexpected name"
  [ "$(plist_value "$config" "Misc:Entries:0:Path")" = "$entry_path" ] ||
    fail "test picker entry has an unexpected device path"
  [ "$(plist_value "$config" "Misc:Entries:0:TextMode")" = "false" ] ||
    fail "test picker entry unexpectedly uses text mode"
  if plist_value "$config" "Misc:Entries:1" >/dev/null 2>&1; then
    fail "live config contains an unreviewed second custom picker entry"
  fi
}

add_test_entry() {
  local config="$1"
  local buddy="/usr/libexec/PlistBuddy"

  "$buddy" -c "Add :Misc:Entries:0 dict" "$config"
  "$buddy" -c "Add :Misc:Entries:0:Arguments string " "$config"
  "$buddy" -c "Add :Misc:Entries:0:Auxiliary bool false" "$config"
  "$buddy" -c "Add :Misc:Entries:0:Comment string $ENTRY_COMMENT" "$config"
  "$buddy" -c "Add :Misc:Entries:0:Enabled bool true" "$config"
  "$buddy" -c "Add :Misc:Entries:0:Flavour string Auto" "$config"
  "$buddy" -c "Add :Misc:Entries:0:Name string $ENTRY_NAME" "$config"
  plutil -insert "Misc.Entries.0.Path" -string "$entry_path" "$config"
  "$buddy" -c "Add :Misc:Entries:0:TextMode bool false" "$config"
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
    --source-device)
      [ "$#" -ge 2 ] || fail "--source-device requires diskXsY"
      source_device="$2"
      shift 2
      ;;
    --target-device)
      [ "$#" -ge 2 ] || fail "--target-device requires diskXsY"
      target_device="$2"
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
  audit|arm|disarm) ;;
  *) fail "mode must be audit, arm, or disarm" ;;
esac
case "$source_device" in
  disk[0-9]*s[0-9]*) ;;
  *) fail "pass the exact live OpenCore ESP as --source-device diskXsY" ;;
esac
case "$target_device" in
  disk[0-9]*s1) ;;
  *) fail "the candidate must be the exact first ESP: --target-device diskXs1" ;;
esac
[ "$source_device" != "$target_device" ] ||
  fail "source and target devices must differ"
[ -x "$ocvalidate" ] || fail "matching OpenCore 1.0.7 ocvalidate is missing"

printf 'Administrator access is required for read-only partition evidence.\n'
sudo -v
mount_read_only "$source_device" ||
  fail "$source_device did not mount read-only"
mount_read_only "$target_device" ||
  fail "$target_device did not mount read-only"
inspect_partition \
  "$source_device" \
  "$SOURCE_VOLUME_NAME" \
  "$SOURCE_MIN_BYTES" \
  "$SOURCE_MAX_BYTES" \
  "toshiba" \
  source_mount_point \
  ""
inspect_partition \
  "$target_device" \
  "$TARGET_VOLUME_NAME" \
  "$TARGET_MIN_BYTES" \
  "$TARGET_MAX_BYTES" \
  "samsung" \
  target_mount_point \
  target_partition_uuid

entry_path="PciRoot(0x0)/Pci(0x17,0x0)/Sata(0x1,0xFFFF,0x0)"
entry_path="$entry_path/HD(1,GPT,$target_partition_uuid,0x800,0x32000)"
entry_path="$entry_path/\\EFI\\OC\\OpenCore.efi"

source_config="$source_mount_point/EFI/OC/config.plist"
candidate_oc="$target_mount_point/EFI/OC"
candidate_config="$candidate_oc/config.plist"
candidate_marker="$candidate_oc/$CANDIDATE_MARKER"
primary_loader="$target_mount_point/EFI/Microsoft/Boot/bootmgfw.efi"
fallback_loader="$target_mount_point/EFI/Boot/bootx64.efi"

[ -f "$source_config" ] || fail "live OpenCore config is missing"
[ -f "$candidate_config" ] || fail "native candidate config is missing"
[ -f "$candidate_oc/OpenCore.efi" ] || fail "native candidate loader is missing"
[ -f "$candidate_marker" ] || fail "native candidate marker is missing"
[ "$(cat "$candidate_marker")" = "optiplex-3040-monterey-native-v1" ] ||
  fail "native candidate marker has unexpected contents"
[ -f "$primary_loader" ] || fail "primary Windows loader is missing"
[ -f "$fallback_loader" ] || fail "fallback Windows loader is missing"
cmp -s "$primary_loader" "$fallback_loader" ||
  fail "Windows primary and fallback loaders differ"
plutil -lint "$source_config" >/dev/null
plutil -lint "$candidate_config" >/dev/null
"$ocvalidate" "$source_config"
"$ocvalidate" "$candidate_config"

armed=0
if plist_value "$source_config" "Misc:Entries:0" >/dev/null 2>&1; then
  verify_test_entry "$source_config"
  armed=1
fi

printf '\nPicker test entry: '
if [ "$armed" -eq 1 ]; then
  printf 'armed and validated\n'
else
  printf 'not armed\n'
fi
printf 'Saved picker default and firmware boot order: unchanged\n'
printf 'Windows loader SHA-256: %s\n' \
  "$(shasum -a 256 "$primary_loader" | awk '{ print $1 }')"

if [ "$mode" = "audit" ]; then
  exit 0
fi
if [ "$mode" = "arm" ] && [ "$armed" -eq 1 ]; then
  exit 0
fi
if [ "$mode" = "disarm" ] && [ "$armed" -eq 0 ]; then
  exit 0
fi

case "$mode:$confirmation" in
  arm:"$ARM_CONFIRMATION") ;;
  disarm:"$DISARM_CONFIRMATION") ;;
  arm:*) fail "arm requires --confirm $ARM_CONFIRMATION" ;;
  disarm:*) fail "disarm requires --confirm $DISARM_CONFIRMATION" ;;
esac

timestamp=$(date -u '+%Y%m%dT%H%M%SZ')
backup_root="$HOME/Documents/OptiPlex-3040-Boot-Backups/$timestamp-picker-$mode"
mkdir -p "$backup_root"
ditto "$source_mount_point/EFI" "$backup_root/MACRECOVERY-EFI"
sudo nvram -xp | tee "$backup_root/nvram-before.xml" >/dev/null
diskutil list > "$backup_root/diskutil-list.txt"

updated_config=$(mktemp "${TMPDIR:-/tmp}/3040-picker-config.XXXXXX")
trap 'rm -f "$updated_config"' EXIT HUP INT TERM
cp "$source_config" "$updated_config"
if [ "$mode" = "arm" ]; then
  add_test_entry "$updated_config"
  verify_test_entry "$updated_config"
else
  /usr/libexec/PlistBuddy -c "Delete :Misc:Entries:0" "$updated_config"
  if plist_value "$updated_config" "Misc:Entries:0" >/dev/null 2>&1; then
    fail "custom picker entry remained after removal"
  fi
fi
plutil -lint "$updated_config" >/dev/null
"$ocvalidate" "$updated_config"

source_rw=0
installed=0
rollback() {
  status=$?
  trap - EXIT HUP INT TERM
  if [ "$status" -ne 0 ] && [ "$installed" -eq 1 ]; then
    printf 'Picker edit failed; restoring the backed-up config.\n' >&2
    if [ "$source_rw" -eq 0 ]; then
      mount_read_write "$source_device" >/dev/null || true
    fi
    sudo cp \
      "$backup_root/MACRECOVERY-EFI/OC/config.plist" \
      "$source_mount_point/EFI/OC/config.plist"
    sync
  fi
  mount_read_only "$source_device" >/dev/null || true
  rm -f "$updated_config"
  exit "$status"
}
trap rollback EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mount_read_write "$source_device" ||
  fail "$source_device did not mount read-write"
source_rw=1
inspect_partition \
  "$source_device" \
  "$SOURCE_VOLUME_NAME" \
  "$SOURCE_MIN_BYTES" \
  "$SOURCE_MAX_BYTES" \
  "toshiba" \
  source_mount_point \
  ""
source_config="$source_mount_point/EFI/OC/config.plist"
sudo cp "$updated_config" "$source_config.new.$$"
sudo mv "$source_config.new.$$" "$source_config"
installed=1
sync
plutil -lint "$source_config" >/dev/null
"$ocvalidate" "$source_config"
if [ "$mode" = "arm" ]; then
  verify_test_entry "$source_config"
else
  if plist_value "$source_config" "Misc:Entries:0" >/dev/null 2>&1; then
    fail "custom picker entry remained in the installed config"
  fi
fi
mount_read_only "$source_device" ||
  fail "$source_device did not remount read-only"
source_rw=0

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
  shasum -a 256 -c SHA256SUMS >/dev/null
)

installed=0
rm -f "$updated_config"
trap - EXIT HUP INT TERM

printf '\nPicker test entry %s and validated.\n' \
  "$([ "$mode" = "arm" ] && printf 'armed' || printf 'removed')"
printf 'Backup: %s\n' "$backup_root"
printf 'The saved default, Windows loaders, BCD, and firmware order are unchanged.\n'
