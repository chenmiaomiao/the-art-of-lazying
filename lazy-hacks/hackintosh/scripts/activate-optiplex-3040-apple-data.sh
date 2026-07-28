#!/bin/bash

set -euo pipefail

readonly EXPECTED_MEDIA_NAME="TOSHIBA DT01ACA100"
readonly EXPECTED_DISK_SIZE="1000204886016"
readonly EXPECTED_PARTITION_OFFSET="488557772800"
readonly EXPECTED_PARTITION_SIZE="214748364800"
readonly EXPECTED_CONTENT="APPLE_APFS"
readonly STAGING_CONTENT="APPLE_HFS"
readonly RECLAIMED_CONTENT="APPLE_KFS"
readonly STAGING_NAME="APFS-STAGING"
readonly EXPECTED_CONFIRMATION="FORMAT-3040-APPLE-DATA"
readonly VOLUME_NAME="Mac Data"
readonly OPTIONAL_VOLUME_NAME="Sequoia Data"

mode=${1:-audit}
confirmation=${2:-}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

plist_value() {
  local plist=$1
  local key=$2
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true
}

[ "$(uname -s)" = "Darwin" ] ||
  fail "run this helper from the installed macOS system"
case "$mode" in
  audit | apply) ;;
  *) fail "usage: $0 audit | $0 apply $EXPECTED_CONFIRMATION" ;;
esac
[ "$mode" != "apply" ] || [ "$confirmation" = "$EXPECTED_CONFIRMATION" ] ||
  fail "apply requires the literal confirmation $EXPECTED_CONFIRMATION"

stage=$(mktemp -d "${TMPDIR:-/tmp}/apple-data-audit.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM

disk_device=""
disk_number=0
while [ "$disk_number" -le 15 ]; do
  candidate="/dev/disk$disk_number"
  plist="$stage/disk$disk_number.plist"
  if diskutil info -plist "$candidate" >"$plist" 2>/dev/null; then
    media_name=$(plist_value "$plist" MediaName)
    total_size=$(plist_value "$plist" TotalSize)
    whole=$(plist_value "$plist" WholeDisk)
    if [ "$media_name" = "$EXPECTED_MEDIA_NAME" ] &&
       [ "$total_size" = "$EXPECTED_DISK_SIZE" ] &&
       [ "$whole" = "true" ]; then
      [ -z "$disk_device" ] ||
        fail "more than one audited Toshiba disk was found"
      disk_device=$candidate
    fi
  fi
  disk_number=$((disk_number + 1))
done
[ -n "$disk_device" ] || fail "the audited Toshiba disk was not found"

partition_device=""
partition_number=1
while [ "$partition_number" -le 15 ]; do
  candidate="${disk_device}s$partition_number"
  plist="$stage/partition-$partition_number.plist"
  if diskutil info -plist "$candidate" >"$plist" 2>/dev/null; then
    partition_offset=$(plist_value "$plist" PartitionMapPartitionOffset)
    partition_size=$(plist_value "$plist" TotalSize)
    partition_content=$(
      plist_value "$plist" Content |
        tr '[:lower:]' '[:upper:]'
    )
    if [ "$partition_offset" = "$EXPECTED_PARTITION_OFFSET" ] &&
       [ "$partition_size" = "$EXPECTED_PARTITION_SIZE" ]; then
      [ -z "$partition_device" ] ||
        fail "more than one Apple data staging partition matched"
      partition_device=$candidate
      partition_plist=$plist
    fi
  fi
  partition_number=$((partition_number + 1))
done
[ -n "$partition_device" ] ||
  fail "the exact Apple data staging partition was not found"

partition_offset=$(plist_value "$partition_plist" PartitionMapPartitionOffset)
partition_size=$(plist_value "$partition_plist" TotalSize)
partition_content=$(
  plist_value "$partition_plist" Content |
    tr '[:lower:]' '[:upper:]'
)
whole=$(plist_value "$partition_plist" WholeDisk)
[ "$whole" = "false" ] || fail "$partition_device is unexpectedly a whole disk"
case "$partition_content" in
  "$EXPECTED_CONTENT") ;;
  "$STAGING_CONTENT")
    [ "$(plist_value "$partition_plist" VolumeName)" = "$STAGING_NAME" ] ||
      fail "unexpected HFS volume occupies the Apple data staging partition"
    ;;
  "$RECLAIMED_CONTENT")
    if [ -n "$(plist_value "$partition_plist" FilesystemType)" ] ||
       [ -n "$(plist_value "$partition_plist" VolumeName)" ]; then
      fail "unexpected filesystem occupies the reclaimed Apple data partition"
    fi
    ;;
  *) fail "Apple data staging partition type changed: $partition_content" ;;
esac

printf 'Disk: %s (%s, %s bytes)\n' \
  "$disk_device" "$EXPECTED_MEDIA_NAME" "$EXPECTED_DISK_SIZE"
printf 'Partition: %s\nOffset: %s\nSize: %s bytes (200 GiB)\nType: %s\n' \
  "$partition_device" \
  "$partition_offset" \
  "$partition_size" \
  "$partition_content"

apfs_report=$(diskutil apfs list 2>/dev/null || true)
container_device=$(
  printf '%s\n' "$apfs_report" |
    awk -v store="$(basename "$partition_device")" '
      /APFS Container Reference:/ {
        container = $NF
      }
      /APFS Physical Store Disk:/ && $NF == store {
        print container
      }
    ' |
    head -n 1
)
if [ -n "$container_device" ]; then
  printf 'Existing APFS container: /dev/%s\n' "$container_device"
else
  printf 'Existing APFS container: none\n'
fi

if [ "$mode" = "audit" ] && [ -z "$container_device" ]; then
  printf 'Audit complete. No disk was changed.\n'
  exit 0
fi

if [ -z "$container_device" ]; then
  if [ "$partition_content" = "$EXPECTED_CONTENT" ]; then
    filesystem=$(plist_value "$partition_plist" FilesystemType)
    volume_name=$(plist_value "$partition_plist" VolumeName)
    if [ -n "$filesystem" ] || [ -n "$volume_name" ]; then
      fail "refusing to reclaim a non-empty APFS staging partition"
    fi
    reclaim_output=$(
      sudo diskutil apfs deleteContainer \
        -force \
        "$partition_device" \
        HFS+ \
        "$STAGING_NAME" \
        0
    )
    printf '%s\n' "$reclaim_output"

    reclaimed_plist="$stage/reclaimed.plist"
    diskutil info -plist "$partition_device" >"$reclaimed_plist"
    [ "$(plist_value "$reclaimed_plist" PartitionMapPartitionOffset)" = \
      "$EXPECTED_PARTITION_OFFSET" ] ||
      fail "partition offset changed while reclaiming the empty store"
    [ "$(plist_value "$reclaimed_plist" TotalSize)" = \
      "$EXPECTED_PARTITION_SIZE" ] ||
      fail "partition size changed while reclaiming the empty store"
    reclaimed_content=$(
      plist_value "$reclaimed_plist" Content |
        tr '[:lower:]' '[:upper:]'
    )
    case "$reclaimed_content" in
      "$STAGING_CONTENT" | "$RECLAIMED_CONTENT") ;;
      *) fail "reclaimed partition has unexpected type: $reclaimed_content" ;;
    esac
  fi

  create_output=$(sudo diskutil apfs createContainer "$partition_device")
  printf '%s\n' "$create_output"
  container_device=$(
    printf '%s\n' "$create_output" |
      sed -n \
        's/.*Created new APFS Container \(disk[0-9][0-9]*\).*/\1/p' |
      head -n 1
  )
  [ -n "$container_device" ] ||
    fail "could not parse the new APFS container identifier"
fi

container_report=$(diskutil apfs list "$container_device")
printf '%s\n' "$container_report" |
  grep -Fq "Physical Store $(basename "$partition_device") " ||
  fail "APFS container is not backed by the audited physical store"
container_volume_count=$(
  printf '%s\n' "$container_report" |
    grep -c 'APFS Volume Disk (Role):' ||
    true
)

volume_device=""
optional_volume_device=""
volume_number=1
while [ "$volume_number" -le 15 ]; do
  candidate="/dev/${container_device}s$volume_number"
  plist="$stage/volume-$volume_number.plist"
  if diskutil info -plist "$candidate" >"$plist" 2>/dev/null; then
    candidate_name=$(plist_value "$plist" VolumeName)
    case "$candidate_name" in
      "$VOLUME_NAME")
        [ -z "$volume_device" ] ||
          fail "more than one APFS volume is named $VOLUME_NAME"
        volume_device=$candidate
        ;;
      "$OPTIONAL_VOLUME_NAME")
        [ -z "$optional_volume_device" ] ||
          fail "more than one APFS volume is named $OPTIONAL_VOLUME_NAME"
        optional_volume_device=$candidate
        ;;
      *) fail "the Apple data container has an unexpected volume: $candidate_name" ;;
    esac
  fi
  volume_number=$((volume_number + 1))
done

if [ -n "$volume_device" ]; then
  expected_volume_count=1
  [ -z "$optional_volume_device" ] ||
    expected_volume_count=2
  [ "$container_volume_count" -eq "$expected_volume_count" ] ||
    fail "the Apple data container has unexpected additional volumes"
elif [ "$container_volume_count" -ne 0 ]; then
  fail "the Apple data container has an unexpected named volume"
fi

if [ "$mode" = "audit" ]; then
  if [ -n "$volume_device" ]; then
    printf 'Existing APFS volume: %s on %s\n' \
      "$VOLUME_NAME" "$volume_device"
    if [ -n "$optional_volume_device" ]; then
      printf 'Optional upgrade volume: %s on %s\n' \
        "$OPTIONAL_VOLUME_NAME" "$optional_volume_device"
    fi
  else
    printf 'Existing APFS volume: none; apply can resume safely\n'
  fi
  printf 'Audit complete. No disk was changed.\n'
  exit 0
fi

if [ -z "$volume_device" ]; then
  add_output=$(
    sudo diskutil apfs addVolume "$container_device" APFS "$VOLUME_NAME"
  )
  printf '%s\n' "$add_output"
  parsed_volume=$(
    printf '%s\n' "$add_output" |
      sed -n \
        's/.*Created new APFS Volume \(disk[0-9][0-9]*s[0-9][0-9]*\).*/\1/p' |
      head -n 1
  )
  [ -n "$parsed_volume" ] ||
    fail "could not parse the new APFS volume identifier"
  volume_device="/dev/$parsed_volume"
fi

verification_plist="$stage/verification.plist"
diskutil info -plist "$volume_device" >"$verification_plist"
filesystem=$(plist_value "$verification_plist" FilesystemType)
volume_name=$(plist_value "$verification_plist" VolumeName)
[ "$filesystem" = "apfs" ] || fail "post-format filesystem is not APFS"
[ "$volume_name" = "$VOLUME_NAME" ] ||
  fail "post-format volume label is not $VOLUME_NAME"

printf 'Activated APFS data volume: %s on %s\n' \
  "$VOLUME_NAME" "$volume_device"
