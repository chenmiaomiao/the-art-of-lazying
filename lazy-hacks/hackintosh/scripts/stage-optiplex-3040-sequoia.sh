#!/bin/bash

set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

readonly DEFAULT_VERSION="15.7.8"
readonly DEFAULT_BUILD="24G824"
readonly SOURCE_APP="/Applications/Install macOS Sequoia.app"
readonly DATA_VOLUME="/Volumes/Mac Data"
readonly TARGET_VOLUME="/Volumes/Sequoia-dev"
readonly STAGE_ROOT="$DATA_VOLUME/Upgrade-Staging/Sequoia"
readonly STAGED_APP="$STAGE_ROOT/Install macOS Sequoia.app"
readonly TARGET_NAME="Sequoia-dev"
readonly DATA_TARGET_NAME="Sequoia Data"
readonly EXPECTED_DATA_MEDIA_NAME="TOSHIBA DT01ACA100"
readonly EXPECTED_DATA_DISK_SIZE="1000204886016"
readonly EXPECTED_DATA_PARTITION_OFFSET="488557772800"
readonly EXPECTED_DATA_PARTITION_SIZE="214748364800"
readonly EXPECTED_SSD_MEDIA_NAME="Samsung SSD 860 PRO 256GB"
readonly EXPECTED_SSD_SIZE="256060514304"
readonly EXPECTED_SSD_PARTITION_OFFSET="109258473472"
readonly EXPECTED_SSD_PARTITION_SIZE="146729017344"
readonly APPLE_NVRAM_GUID="7C436110-AB2A-4BBB-A880-FE41995C9F82"

mode="${1:-audit}"
version="${SEQUOIA_VERSION:-$DEFAULT_VERSION}"
build="${SEQUOIA_BUILD:-$DEFAULT_BUILD}"
efi_config="${EFI_CONFIG:-}"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

plist_value() {
  local plist=$1
  local key=$2

  /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true
}

efi_value() {
  local path=$1

  /usr/libexec/PlistBuddy -c "Print $path" "$efi_config" 2>/dev/null
}

find_exact_partition() {
  local expected_media_name=$1
  local expected_disk_size=$2
  local expected_partition_offset=$3
  local expected_partition_size=$4
  local description=$5
  local disk_number=0
  local partition_number
  local candidate
  local plist
  local media_name
  local size
  local whole
  local disk_device=""
  local partition_device=""

  while [ "$disk_number" -le 15 ]; do
    candidate="/dev/disk$disk_number"
    plist="$workdir/disk-$disk_number.plist"
    if diskutil info -plist "$candidate" >"$plist" 2>/dev/null; then
      media_name=$(plist_value "$plist" MediaName)
      size=$(plist_value "$plist" TotalSize)
      whole=$(plist_value "$plist" WholeDisk)
      if [ "$media_name" = "$expected_media_name" ] &&
         [ "$size" = "$expected_disk_size" ] &&
         [ "$whole" = "true" ]; then
        [ -z "$disk_device" ] ||
          fail "more than one audited $description disk was found"
        disk_device=$candidate
      fi
    fi
    disk_number=$((disk_number + 1))
  done
  [ -n "$disk_device" ] || fail "the audited $description disk was not found"

  partition_number=1
  while [ "$partition_number" -le 15 ]; do
    candidate="${disk_device}s$partition_number"
    plist="$workdir/partition-$partition_number.plist"
    if diskutil info -plist "$candidate" >"$plist" 2>/dev/null &&
       [ "$(plist_value "$plist" PartitionMapPartitionOffset)" = \
         "$expected_partition_offset" ] &&
       [ "$(plist_value "$plist" TotalSize)" = \
         "$expected_partition_size" ]; then
      [ -z "$partition_device" ] ||
        fail "more than one $description partition matched"
      partition_device=$candidate
    fi
    partition_number=$((partition_number + 1))
  done
  [ -n "$partition_device" ] ||
    fail "the exact $description partition was not found"
  printf '%s\n' "$partition_device"
}

find_container() {
  local partition_device=$1
  local store

  store=$(basename "$partition_device")
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
  local volume_number=1
  local candidate
  local plist
  local found=""

  while [ "$volume_number" -le 15 ]; do
    candidate="/dev/${container}s$volume_number"
    plist="$workdir/${container}s$volume_number.plist"
    if diskutil info -plist "$candidate" >"$plist" 2>/dev/null &&
       [ "$(plist_value "$plist" VolumeName)" = "$expected_name" ]; then
      [ -z "$found" ] ||
        fail "more than one APFS volume is named $expected_name"
      found=$candidate
    fi
    volume_number=$((volume_number + 1))
  done
  printf '%s\n' "$found"
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

audit_efi() {
  local boot_args
  local product_name
  local kernel_add

  [ -n "$efi_config" ] || {
    printf 'EFI_CONFIG is unset; skipped OpenCore audit.\n'
    return 0
  }
  [ -f "$efi_config" ] || fail "OpenCore config is missing: $efi_config"
  plutil -lint "$efi_config"

  product_name=$(efi_value ":PlatformInfo:Generic:SystemProductName")
  [ "$product_name" = "iMac17,1" ] ||
    fail "unexpected OpenCore SystemProductName: $product_name"
  boot_args=$(efi_value ":NVRAM:Add:$APPLE_NVRAM_GUID:boot-args")
  case " $boot_args " in
    *" -no_compat_check "*) ;;
    *) fail "OpenCore boot-args is missing -no_compat_check" ;;
  esac
  case " $boot_args " in
    *" revpatch=sbvmm "*) ;;
    *) fail "OpenCore boot-args is missing revpatch=sbvmm" ;;
  esac
  case " $boot_args " in
    *" -igfxsklaskbl "*) ;;
    *) fail "OpenCore boot-args is missing -igfxsklaskbl" ;;
  esac
  kernel_add=$(efi_value ":Kernel:Add")
  printf '%s\n' "$kernel_add" |
    grep -Fq "RestrictEvents.kext" ||
    fail "OpenCore does not enable RestrictEvents.kext"
  printf '%s\n' "$kernel_add" |
    grep -Fq "WhateverGreen.kext" ||
    fail "OpenCore does not enable WhateverGreen.kext"
  printf 'OpenCore Sequoia compatibility audit passed: %s\n' "$efi_config"
}

verify_installer() {
  local app=$1
  local install_assistant
  local startosinstall
  local shared_support
  local mount_dir
  local metadata_match=""
  local metadata

  [ -d "$app" ] || fail "installer app does not exist: $app"

  install_assistant="$app/Contents/MacOS/InstallAssistant"
  startosinstall="$app/Contents/Resources/startosinstall"
  shared_support="$app/Contents/SharedSupport/SharedSupport.dmg"
  [ -f "$install_assistant" ] || fail "InstallAssistant is missing"
  [ -f "$startosinstall" ] || fail "startosinstall is missing"
  [ -f "$shared_support" ] || fail "SharedSupport.dmg is missing"

  codesign --verify --strict --verbose=2 "$install_assistant"
  codesign --verify --strict --verbose=2 "$startosinstall"
  hdiutil verify "$shared_support"

  mount_dir=$(mktemp -d "${TMPDIR:-/tmp}/sequoia-verify.XXXXXX")
  installer_mount=$mount_dir
  hdiutil attach \
    -readonly \
    -nobrowse \
    -mountpoint "$mount_dir" \
    "$shared_support" >/dev/null
  installer_mounted=1
  for metadata in \
    "$mount_dir"/com_apple_MobileAsset_MacSoftwareUpdate/*.json; do
    [ -f "$metadata" ] || continue
    if grep -Fq "\"OSVersion\": \"$version\"" "$metadata" &&
       grep -Fq "\"Build\": \"$build\"" "$metadata"; then
      metadata_match=$metadata
      break
    fi
  done
  [ -n "$metadata_match" ] ||
    fail "no installer metadata matches Sequoia $version build $build"

  hdiutil detach "$mount_dir" >/dev/null
  installer_mounted=0
  installer_mount=""
  rmdir "$mount_dir"

  shared_support_sha256=$(
    shasum -a 256 "$shared_support" |
      awk '{print $1}'
  )
  installer_cdhash=$(
    codesign -dvvv "$install_assistant" 2>&1 |
      sed -n 's/^CDHash=//p' |
      head -n 1
  )
  printf 'Verified Sequoia %s (%s): %s\n' "$version" "$build" "$app"
}

[ "$(uname -s)" = "Darwin" ] || fail "run this script on macOS"
[ "$(uname -m)" = "x86_64" ] || fail "expected the Intel OptiPlex installation"
case "$mode" in
  audit | fetch) ;;
  *) fail "mode must be audit or fetch" ;;
esac

workdir=$(mktemp -d "${TMPDIR:-/tmp}/sequoia-stage.XXXXXX")
installer_mount=""
installer_mounted=0
status_temporary=""
cleanup() {
  status=$?
  trap - EXIT
  if [ "$installer_mounted" -eq 1 ] && [ -n "$installer_mount" ]; then
    hdiutil detach "$installer_mount" >/dev/null 2>&1 || true
  fi
  if [ -n "$status_temporary" ]; then
    rm -f "$status_temporary"
  fi
  rm -rf "$workdir"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

current_version=$(sw_vers -productVersion)
data_partition=$(
  find_exact_partition \
    "$EXPECTED_DATA_MEDIA_NAME" \
    "$EXPECTED_DATA_DISK_SIZE" \
    "$EXPECTED_DATA_PARTITION_OFFSET" \
    "$EXPECTED_DATA_PARTITION_SIZE" \
    "1 TB Apple data store"
)
data_container=$(find_container "$data_partition")
[ -n "$data_container" ] ||
  fail "the audited Apple data partition is not an APFS physical store"
data_device=$(find_named_volume "$data_container" "Mac Data")
[ -n "$data_device" ] || fail "Mac Data is missing from $data_container"
[ -d "$DATA_VOLUME" ] || fail "Mac Data is not mounted"
[ "$(df "$DATA_VOLUME" | awk 'NR == 2 { print $1 }')" = "$data_device" ] ||
  fail "the Mac Data mount does not use the audited APFS volume"
data_target_device=$(find_named_volume "$data_container" "$DATA_TARGET_NAME")
[ -n "$data_target_device" ] ||
  fail "$DATA_TARGET_NAME is missing from $data_container"

ssd_partition=$(
  find_exact_partition \
    "$EXPECTED_SSD_MEDIA_NAME" \
    "$EXPECTED_SSD_SIZE" \
    "$EXPECTED_SSD_PARTITION_OFFSET" \
    "$EXPECTED_SSD_PARTITION_SIZE" \
    "expanded Monterey SSD"
)
ssd_container=$(find_container "$ssd_partition")
[ -n "$ssd_container" ] ||
  fail "the audited SSD partition is not an APFS physical store"
root_plist="$workdir/root.plist"
diskutil info -plist / >"$root_plist"
[ "$(plist_value "$root_plist" APFSContainerReference)" = "$ssd_container" ] ||
  fail "the running macOS root does not use the audited SSD container"
target_device=$(find_named_volume "$ssd_container" "$TARGET_NAME")
[ -n "$target_device" ] ||
  fail "$TARGET_NAME is missing; run prepare-optiplex-3040-sequoia-ssd.sh"
target_consumed=$(volume_consumed_bytes "$ssd_container" "$TARGET_NAME")
[ -n "$target_consumed" ] || fail "could not read $TARGET_NAME usage"
[ "$target_consumed" -lt 100000000 ] ||
  fail "$TARGET_NAME is not empty enough for a prepared upgrade target"

audit_efi
printf 'Current macOS: %s\n' "$current_version"
printf 'Apple staging store: %s -> %s\n' \
  "$data_partition" "$data_container"
printf 'Mac Data: %s (%s)\n' "$DATA_VOLUME" "$data_device"
printf 'Sequoia data: %s (%s)\n' "$DATA_TARGET_NAME" "$data_target_device"
printf 'SSD target: %s (%s, %s bytes used)\n' \
  "$TARGET_VOLUME" "$target_device" "$target_consumed"

if [ "$mode" = "audit" ]; then
  if [ -d "$STAGED_APP" ]; then
    verify_installer "$STAGED_APP"
  else
    printf 'Staged installer: not downloaded\n'
  fi
  printf 'Audit complete. No installer was downloaded or opened.\n'
  exit 0
fi

[ -n "$efi_config" ] ||
  fail "set EFI_CONFIG to an accepted OpenCore candidate before fetch"
mkdir -p "$STAGE_ROOT"

if [ -d "$STAGED_APP" ]; then
  verify_installer "$STAGED_APP"
else
  if [ ! -d "$SOURCE_APP" ]; then
    sudo softwareupdate \
      --fetch-full-installer \
      --full-installer-version "$version"
  fi
  [ -d "$SOURCE_APP" ] ||
    fail "softwareupdate did not create $SOURCE_APP"
  verify_installer "$SOURCE_APP"

  stage_temporary="$STAGE_ROOT/.Install macOS Sequoia.app.copying"
  rm -rf "$stage_temporary"
  ditto --rsrc --extattr "$SOURCE_APP" "$stage_temporary"
  verify_installer "$stage_temporary"
  mv "$stage_temporary" "$STAGED_APP"
  verify_installer "$STAGED_APP"
  sudo rm -rf "$SOURCE_APP"
fi

if [ -d "$SOURCE_APP" ]; then
  verify_installer "$SOURCE_APP"
  sudo rm -rf "$SOURCE_APP"
fi

status_path="$STAGE_ROOT/status.txt"
status_temporary="$STAGE_ROOT/.status.txt.$$"
{
  printf 'staged_at_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'current_macos=%s\n' "$current_version"
  printf 'installer_version=%s\n' "$version"
  printf 'installer_build=%s\n' "$build"
  printf 'installer_path=%s\n' "$STAGED_APP"
  printf 'target_volume=%s\n' "$TARGET_VOLUME"
  printf 'target_device=%s\n' "$target_device"
  printf 'shared_support_sha256=%s\n' "$shared_support_sha256"
  printf 'install_assistant_cdhash=%s\n' "$installer_cdhash"
  printf 'upgrade_started=no\n'
} >"$status_temporary"
chmod 644 "$status_temporary"
mv -f "$status_temporary" "$status_path"
status_temporary=""

printf 'Sequoia %s (%s) is staged on Mac Data and verified.\n' \
  "$version" "$build"
printf 'The installer was not opened and the upgrade was not started.\n'
