#!/bin/bash

set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

readonly EXPECTED_SSD_NAME="Samsung SSD 860 PRO 256GB"
readonly EXPECTED_SSD_SIZE="256060514304"
readonly MAIN_OFFSET="109258473472"
readonly MAIN_SIZE_BEFORE="127523901440"
readonly SPARE_OFFSET="236782374912"
readonly SPARE_SIZE="19205115904"
readonly MAIN_SIZE_AFTER="146729017344"
readonly RECOVERY_FIX_OFFSET="255987490816"
readonly RECOVERY_FIX_SIZE="73003008"
readonly TOSHIBA_NAME="TOSHIBA DT01ACA100"
readonly TOSHIBA_SIZE="1000204886016"
readonly DATA_STORE_OFFSET="488557772800"
readonly DATA_STORE_SIZE="214748364800"
readonly CONFIRMATION="PREPARE-3040-SEQUOIA-SSD"

mode="${1:-audit}"
confirmation="${2:-}"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

plist_value() {
  local plist=$1
  local key=$2

  /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true
}

find_disk() {
  local expected_name=$1
  local expected_size=$2
  local number=0
  local candidate
  local plist
  local found=""

  while [ "$number" -le 15 ]; do
    candidate="/dev/disk$number"
    plist="$workdir/disk-$number.plist"
    if diskutil info -plist "$candidate" >"$plist" 2>/dev/null &&
       [ "$(plist_value "$plist" MediaName)" = "$expected_name" ] &&
       [ "$(plist_value "$plist" TotalSize)" = "$expected_size" ] &&
       [ "$(plist_value "$plist" WholeDisk)" = "true" ]; then
      [ -z "$found" ] || fail "more than one $expected_name disk was found"
      found=$candidate
    fi
    number=$((number + 1))
  done
  [ -n "$found" ] || fail "the audited $expected_name disk was not found"
  printf '%s\n' "$found"
}

find_partition() {
  local whole_disk=$1
  local expected_offset=$2
  local expected_size=$3
  local number=1
  local candidate
  local plist
  local found=""

  while [ "$number" -le 15 ]; do
    candidate="${whole_disk}s$number"
    plist="$workdir/$(basename "$whole_disk")s$number.plist"
    if diskutil info -plist "$candidate" >"$plist" 2>/dev/null &&
       [ "$(plist_value "$plist" PartitionMapPartitionOffset)" = \
         "$expected_offset" ] &&
       [ "$(plist_value "$plist" TotalSize)" = "$expected_size" ]; then
      [ -z "$found" ] ||
        fail "more than one partition matched offset $expected_offset"
      found=$candidate
    fi
    number=$((number + 1))
  done
  printf '%s\n' "$found"
}

find_container() {
  local partition=$1
  local store

  store=$(basename "$partition")
  diskutil apfs list |
    awk -v store="$store" '
      /APFS Container Reference:/ {
        container = $NF
      }
      /APFS Physical Store Disk:/ && $NF == store {
        print container
      }
    ' |
    head -n 1
}

find_named_volume() {
  local container=$1
  local expected_name=$2
  local number=1
  local candidate
  local plist
  local found=""

  while [ "$number" -le 20 ]; do
    candidate="/dev/${container}s$number"
    plist="$workdir/${container}s$number.plist"
    if diskutil info -plist "$candidate" >"$plist" 2>/dev/null &&
       [ "$(plist_value "$plist" VolumeName)" = "$expected_name" ]; then
      [ -z "$found" ] ||
        fail "more than one volume is named $expected_name"
      found=$candidate
    fi
    number=$((number + 1))
  done
  printf '%s\n' "$found"
}

container_volume_count() {
  local container=$1

  diskutil apfs list "$container" |
    grep -c "APFS Volume Disk (Role)"
}

volume_consumed_bytes() {
  local container=$1
  local expected_name=$2

  diskutil apfs list "$container" |
    awk -v expected="$expected_name" '
      /APFS Volume Disk \(Role\):/ {
        matching = 0
      }
      /Name:/ {
        line = $0
        sub(/^.*Name:[[:space:]]*/, "", line)
        sub(/[[:space:]]+\(.*/, "", line)
        matching = (line == expected)
      }
      matching && /Capacity Consumed:/ {
        print $3
        exit
      }
    '
}

assert_metadata_only() {
  local volume=$1
  local expected_name=$2
  local plist="$workdir/metadata-volume.plist"
  local mount_point
  local entry

  diskutil mount readOnly "$volume" >/dev/null
  mounted_volume=$volume
  diskutil info -plist "$volume" >"$plist"
  mount_point=$(plist_value "$plist" MountPoint)
  [ -d "$mount_point" ] || fail "$expected_name did not mount read-only"

  while IFS= read -r entry; do
    case "$(basename "$entry")" in
      .Spotlight-V100 | .Trashes | .fseventsd) ;;
      *) fail "$expected_name contains non-metadata content: $entry" ;;
    esac
  done < <(find "$mount_point" -mindepth 1 -maxdepth 1 -print)

  diskutil unmount "$volume" >/dev/null
  mounted_volume=""
}

record_disk_geometry() {
  local disk=$1
  local destination=$2
  local number=0
  local candidate

  mkdir -p "$destination"
  diskutil info -plist "$disk" >"$destination/whole-disk.plist"
  while [ "$number" -le 15 ]; do
    candidate="${disk}s$number"
    if diskutil info -plist "$candidate" \
      >"$destination/$(basename "$candidate").plist" 2>/dev/null; then
      :
    else
      rm -f "$destination/$(basename "$candidate").plist"
    fi
    number=$((number + 1))
  done
}

record_optional_gpt() {
  local disk=$1
  local destination=$2
  local error_file="${destination%.txt}.stderr.txt"
  local output

  if output=$(sudo gpt -r show "$disk" 2>&1); then
    printf '%s\n' "$output" >"$destination"
    rm -f "$error_file"
  else
    printf '%s\n' "$output" >"$error_file"
    printf '%s\n' \
      "Raw GPT access was denied; use the adjacent diskutil plist geometry." \
      >"$destination"
  fi
}

rename_volume() {
  local volume=$1
  local new_name=$2

  diskutil mount "$volume" >/dev/null
  sudo diskutil renameVolume "$volume" "$new_name"
}

[ "$(uname -s)" = "Darwin" ] || fail "run this script on macOS"
case "$mode" in
  audit | apply) ;;
  *) fail "mode must be audit or apply" ;;
esac
if [ "$mode" = "apply" ]; then
  [ "$confirmation" = "$CONFIRMATION" ] ||
    fail "apply requires literal confirmation $CONFIRMATION"
fi

workdir=$(mktemp -d "${TMPDIR:-/tmp}/sequoia-ssd.XXXXXX")
mounted_volume=""
cleanup() {
  status=$?
  trap - EXIT
  if [ -n "$mounted_volume" ]; then
    diskutil unmount "$mounted_volume" >/dev/null 2>&1 || true
  fi
  rm -rf "$workdir"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

ssd=$(find_disk "$EXPECTED_SSD_NAME" "$EXPECTED_SSD_SIZE")
main_before=$(find_partition "$ssd" "$MAIN_OFFSET" "$MAIN_SIZE_BEFORE")
main_after=$(find_partition "$ssd" "$MAIN_OFFSET" "$MAIN_SIZE_AFTER")
spare=$(find_partition "$ssd" "$SPARE_OFFSET" "$SPARE_SIZE")
recovery_fix=$(
  find_partition "$ssd" "$RECOVERY_FIX_OFFSET" "$RECOVERY_FIX_SIZE"
)
[ -n "$recovery_fix" ] || fail "the exact RECOVERY-FIX partition is missing"

if [ -n "$main_before" ] && [ -n "$main_after" ]; then
  fail "both pre-expansion and post-expansion SSD layouts matched"
elif [ -n "$main_before" ]; then
  main_partition=$main_before
  layout="before"
  [ -n "$spare" ] || fail "the exact 19 GB spare partition is missing"
elif [ -n "$main_after" ]; then
  main_partition=$main_after
  layout="after"
  [ -z "$spare" ] ||
    fail "the spare partition still exists beside an expanded main container"
else
  fail "the Monterey APFS partition has unexpected geometry"
fi

main_container=$(find_container "$main_partition")
[ -n "$main_container" ] ||
  fail "the Monterey partition is not an APFS physical store"
root_plist="$workdir/root.plist"
diskutil info -plist / >"$root_plist"
[ "$(plist_value "$root_plist" APFSContainerReference)" = "$main_container" ] ||
  fail "the running root does not use the audited SSD container"
[ "$(sw_vers -productVersion)" = "12.7.6" ] ||
  fail "the running system is not the accepted Monterey 12.7.6"

target=$(find_named_volume "$main_container" "Sequoia-dev")
old_target=$(find_named_volume "$main_container" "Tahoe-dev")
if [ -n "$target" ] && [ -n "$old_target" ]; then
  fail "both Tahoe-dev and Sequoia-dev exist in the SSD container"
elif [ -n "$old_target" ]; then
  target=$old_target
  target_name="Tahoe-dev"
elif [ -n "$target" ]; then
  target_name="Sequoia-dev"
else
  fail "the empty SSD development target is missing"
fi

target_consumed=$(volume_consumed_bytes "$main_container" "$target_name")
[ -n "$target_consumed" ] || fail "could not read $target_name usage"
[ "$target_consumed" -lt 100000000 ] ||
  fail "$target_name consumes more than the 100 MB safety ceiling"

toshiba=$(find_disk "$TOSHIBA_NAME" "$TOSHIBA_SIZE")
data_store=$(find_partition "$toshiba" "$DATA_STORE_OFFSET" "$DATA_STORE_SIZE")
[ -n "$data_store" ] || fail "the exact 1 TB Apple data store is missing"
data_container=$(find_container "$data_store")
[ -n "$data_container" ] || fail "the 1 TB Apple store is not APFS"
data_target=$(find_named_volume "$data_container" "Sequoia Data")
old_data_target=$(find_named_volume "$data_container" "Sequoia")
if [ -n "$data_target" ] && [ -n "$old_data_target" ]; then
  fail "both Sequoia and Sequoia Data exist on the 1 TB store"
elif [ -n "$old_data_target" ]; then
  data_target=$old_data_target
  data_target_name="Sequoia"
elif [ -n "$data_target" ]; then
  data_target_name="Sequoia Data"
else
  fail "the prepared 1 TB Sequoia data volume is missing"
fi

printf 'SSD: %s\n' "$ssd"
printf 'SSD layout: %s expansion\n' "$layout"
printf 'Monterey container: %s (%s)\n' "$main_container" "$main_partition"
printf 'Development target: %s (%s, %s bytes used)\n' \
  "$target_name" "$target" "$target_consumed"
printf 'RECOVERY-FIX partition: %s\n' "$recovery_fix"
printf '1 TB data target: %s (%s)\n' "$data_target_name" "$data_target"

if [ "$layout" = "before" ]; then
  spare_container=$(find_container "$spare")
  [ -n "$spare_container" ] || fail "the spare partition is not APFS"
  [ "$(container_volume_count "$spare_container")" -eq 1 ] ||
    fail "the spare container does not contain exactly one volume"
  spare_volume=$(find_named_volume "$spare_container" "Mac Spare 19GB")
  [ -n "$spare_volume" ] || fail "Mac Spare 19GB is missing"
  spare_consumed=$(
    volume_consumed_bytes "$spare_container" "Mac Spare 19GB"
  )
  [ -n "$spare_consumed" ] || fail "could not read spare usage"
  [ "$spare_consumed" -lt 100000000 ] ||
    fail "Mac Spare 19GB consumes more than the 100 MB safety ceiling"
  printf 'Reclaimable spare: %s (%s, %s bytes used)\n' \
    "$spare_container" "$spare_volume" "$spare_consumed"
fi

if [ "$mode" = "audit" ]; then
  printf 'Audit complete. No disk or volume was changed.\n'
  exit 0
fi

sudo -v
timestamp=$(date -u '+%Y%m%dT%H%M%SZ')
backup_dir="$HOME/Documents/OptiPlex-3040-Disk-Backups/$timestamp"
mkdir -p "$backup_dir"
diskutil list >"$backup_dir/diskutil-list-before.txt"
diskutil apfs list >"$backup_dir/diskutil-apfs-before.txt"
record_disk_geometry "$ssd" "$backup_dir/ssd-geometry-before"
record_optional_gpt "$ssd" "$backup_dir/gpt-ssd-before.txt"

assert_metadata_only "$target" "$target_name"
if [ "$layout" = "before" ]; then
  assert_metadata_only "$spare_volume" "Mac Spare 19GB"
  sudo diskutil apfs deleteContainer "$spare_container"
  spare=$(
    find_partition "$ssd" "$SPARE_OFFSET" "$SPARE_SIZE"
  )
  if [ -n "$spare" ]; then
    sudo diskutil eraseVolume free none "$spare"
  fi
  sudo diskutil apfs resizeContainer "$main_container" 0
fi

if [ "$target_name" = "Tahoe-dev" ]; then
  rename_volume "$target" "Sequoia-dev"
fi
if [ "$data_target_name" = "Sequoia" ]; then
  rename_volume "$data_target" "Sequoia Data"
fi

main_partition=$(
  find_partition "$ssd" "$MAIN_OFFSET" "$MAIN_SIZE_AFTER"
)
[ -n "$main_partition" ] ||
  fail "the expanded Monterey partition has unexpected geometry"
main_container=$(find_container "$main_partition")
target=$(find_named_volume "$main_container" "Sequoia-dev")
[ -n "$target" ] || fail "Sequoia-dev is missing after preparation"
data_target=$(find_named_volume "$data_container" "Sequoia Data")
[ -n "$data_target" ] || fail "Sequoia Data is missing after preparation"
recovery_fix=$(
  find_partition "$ssd" "$RECOVERY_FIX_OFFSET" "$RECOVERY_FIX_SIZE"
)
[ -n "$recovery_fix" ] || fail "RECOVERY-FIX moved or disappeared"

diskutil list >"$backup_dir/diskutil-list-after.txt"
diskutil apfs list >"$backup_dir/diskutil-apfs-after.txt"
record_disk_geometry "$ssd" "$backup_dir/ssd-geometry-after"
record_optional_gpt "$ssd" "$backup_dir/gpt-ssd-after.txt"

status_dir="/Volumes/Mac Data/Upgrade-Staging/Sequoia"
mkdir -p "$status_dir"
{
  printf 'prepared_at_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'monterey_container=%s\n' "$main_container"
  printf 'sequoia_target=%s\n' "$target"
  printf 'sequoia_target_name=Sequoia-dev\n'
  printf 'installer_staging_volume=Mac Data\n'
  printf 'data_volume_name=Sequoia Data\n'
  printf 'recovery_fix_partition=%s\n' "$recovery_fix"
  printf 'backup_dir=%s\n' "$backup_dir"
  printf 'upgrade_started=no\n'
} >"$status_dir/ssd-target-status.txt"

printf 'Expanded the Monterey SSD container and prepared Sequoia-dev.\n'
printf 'Renamed the 1 TB target to Sequoia Data.\n'
printf 'Evidence: %s\n' "$backup_dir"
printf 'No installer was opened and no startup disk was changed.\n'
