#!/bin/bash

set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
export LC_ALL=C
export LANG=C

readonly CONFIRMATION="STAGE-3040-MONTEREY-NATIVE"
readonly SOURCE_VOLUME_NAME="MACRECOVERY"
readonly TARGET_VOLUME_NAME="WIN10 EFI"
readonly SOURCE_MIN_BYTES=4200000000
readonly SOURCE_MAX_BYTES=4400000000
readonly TARGET_MIN_BYTES=100000000
readonly TARGET_MAX_BYTES=110000000
readonly APPLE_NVRAM_GUID="7C436110-AB2A-4BBB-A880-FE41995C9F82"
readonly IGPU_KEY="PciRoot(0x0)/Pci(0x2,0x0)"
readonly KBL_PLATFORM_DATA="AAASWQ=="
readonly KBL_DEVICE_DATA="ElkAAA=="
readonly SKL_PLATFORM_DATA="AAASGQ=="
readonly PATCH_ENABLE_DATA="AQAAAA=="
readonly STOLEN_MEMORY_DATA="AAAwAQ=="
readonly FRAMEBUFFER_MEMORY_DATA="AACQAA=="
readonly MARKER_NAME=".optiplex-3040-monterey-native"

mode="${1:-audit}"
source_device=""
target_device=""
ocvalidate=""
confirmation=""
source_mount_point=""
source_whole_disk=""
source_parent_model=""
target_mount_point=""
target_whole_disk=""
target_parent_model=""

usage() {
  cat <<'EOF'
Usage:
  stage-optiplex-3040-monterey-native-graphics.sh audit \
    --source-device diskXsY \
    --target-device diskXsY \
    --ocvalidate /path/to/OpenCore-1.0.7/Utilities/ocvalidate/ocvalidate

  stage-optiplex-3040-monterey-native-graphics.sh apply \
    --source-device diskXsY \
    --target-device diskXsY \
    --ocvalidate /path/to/OpenCore-1.0.7/Utilities/ocvalidate/ocvalidate \
    --confirm STAGE-3040-MONTEREY-NATIVE

The script copies the currently bootable OpenCore tree to the Windows SSD ESP
as a separate, one-time test candidate. Only the copied config is changed:

  - Kaby Lake platform 0x59120000 -> native Skylake 0x19120000
  - remove the spoofed Kaby Lake device-id 0x5912
  - remove -igfxsklaskbl

The Microsoft primary and fallback loaders, BCD, live OpenCore ESP, partition
tables, firmware boot order, and saved picker default are never edited.
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

plist_raw() {
  local plist="$1"
  local key="$2"

  plutil -extract "$key" raw -o - "$plist" 2>/dev/null
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

  partition_plist=$(mktemp "${TMPDIR:-/tmp}/3040-native-partition.XXXXXX")
  whole_plist=$(mktemp "${TMPDIR:-/tmp}/3040-native-whole.XXXXXX")
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

mount_read_only() {
  local device="$1"
  local attempt=0

  sudo diskutil unmount "$device" >/dev/null 2>&1 || true
  sudo diskutil mount readOnly "$device" >/dev/null || return 1
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
  sudo diskutil mount "$device" >/dev/null || return 1
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

remove_boot_argument() {
  local arguments="$1"
  local remove="$2"
  local token
  local result=""
  local found=0

  for token in $arguments; do
    if [ "$token" = "$remove" ]; then
      found=$((found + 1))
      continue
    fi
    if [ -n "$result" ]; then
      result="$result $token"
    else
      result="$token"
    fi
  done
  [ "$found" -eq 1 ] ||
    fail "expected exactly one $remove boot argument, found $found"
  printf '%s\n' "$result"
}

verify_framebuffer_memory() {
  local config="$1"
  local prefix="DeviceProperties.Add.$IGPU_KEY"

  [ "$(plist_raw "$config" "$prefix.framebuffer-patch-enable")" = \
    "$PATCH_ENABLE_DATA" ] ||
    fail "unexpected framebuffer-patch-enable in $config"
  [ "$(plist_raw "$config" "$prefix.framebuffer-stolenmem")" = \
    "$STOLEN_MEMORY_DATA" ] ||
    fail "unexpected framebuffer-stolenmem in $config"
  [ "$(plist_raw "$config" "$prefix.framebuffer-fbmem")" = \
    "$FRAMEBUFFER_MEMORY_DATA" ] ||
    fail "unexpected framebuffer-fbmem in $config"
}

verify_source_config() {
  local config="$1"
  local prefix="DeviceProperties.Add.$IGPU_KEY"
  local boot_args

  plutil -lint "$config" >/dev/null
  "$ocvalidate" "$config"
  [ "$(plist_value "$config" "PlatformInfo:Generic:SystemProductName")" = \
    "iMac17,1" ] ||
    fail "source OpenCore does not use iMac17,1"
  [ "$(plist_raw "$config" "$prefix.AAPL,ig-platform-id")" = \
    "$KBL_PLATFORM_DATA" ] ||
    fail "source config is not the reviewed Kaby Lake graphics state"
  [ "$(plist_raw "$config" "$prefix.device-id")" = "$KBL_DEVICE_DATA" ] ||
    fail "source config has an unexpected graphics device-id"
  boot_args=$(
    plist_value "$config" "NVRAM:Add:$APPLE_NVRAM_GUID:boot-args"
  )
  case " $boot_args " in
    *" -igfxsklaskbl "*) ;;
    *) fail "source config is missing -igfxsklaskbl" ;;
  esac
  verify_framebuffer_memory "$config"
}

verify_candidate_config() {
  local config="$1"
  local prefix="DeviceProperties.Add.$IGPU_KEY"
  local boot_args

  plutil -lint "$config" >/dev/null
  "$ocvalidate" "$config"
  [ "$(plist_value "$config" "PlatformInfo:Generic:SystemProductName")" = \
    "iMac17,1" ] ||
    fail "candidate OpenCore does not use iMac17,1"
  [ "$(plist_raw "$config" "$prefix.AAPL,ig-platform-id")" = \
    "$SKL_PLATFORM_DATA" ] ||
    fail "candidate does not use native Skylake platform 0x19120000"
  if plist_raw "$config" "$prefix.device-id" >/dev/null 2>&1; then
    fail "candidate still contains a spoofed graphics device-id"
  fi
  boot_args=$(
    plist_value "$config" "NVRAM:Add:$APPLE_NVRAM_GUID:boot-args"
  )
  case " $boot_args " in
    *" -igfxsklaskbl "*)
      fail "candidate still contains -igfxsklaskbl"
      ;;
  esac
  verify_framebuffer_memory "$config"
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
  audit|apply) ;;
  *) fail "mode must be audit or apply" ;;
esac
case "$source_device" in
  disk[0-9]*s[0-9]*) ;;
  *) fail "pass the exact live OpenCore ESP as --source-device diskXsY" ;;
esac
case "$target_device" in
  disk[0-9]*s[0-9]*) ;;
  *) fail "pass the exact Windows ESP as --target-device diskXsY" ;;
esac
[ "$source_device" != "$target_device" ] ||
  fail "source and target devices must be different"
[ -x "$ocvalidate" ] || fail "matching OpenCore 1.0.7 ocvalidate is missing"
ocvalidate=$(absolute_path "$ocvalidate")

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
  source
inspect_partition \
  "$target_device" \
  "$TARGET_VOLUME_NAME" \
  "$TARGET_MIN_BYTES" \
  "$TARGET_MAX_BYTES" \
  "samsung" \
  target

source_oc="$source_mount_point/EFI/OC"
source_config="$source_oc/config.plist"
target_efi="$target_mount_point/EFI"
target_oc="$target_efi/OC"
target_config="$target_oc/config.plist"
target_marker="$target_oc/$MARKER_NAME"
primary_loader="$target_efi/Microsoft/Boot/bootmgfw.efi"
fallback_loader="$target_efi/Boot/bootx64.efi"
bcd="$target_efi/Microsoft/Boot/BCD"

[ -f "$source_oc/OpenCore.efi" ] || fail "source OpenCore.efi is missing"
[ -f "$source_config" ] || fail "source config.plist is missing"
[ -f "$primary_loader" ] || fail "primary Windows loader is missing"
[ -f "$fallback_loader" ] || fail "fallback Windows loader is missing"
[ -f "$bcd" ] || fail "Windows BCD is missing"
cmp -s "$primary_loader" "$fallback_loader" ||
  fail "Windows primary and fallback loaders are not byte-identical"
/usr/bin/file "$primary_loader" | grep -Fq "EFI application" ||
  fail "primary Windows loader is not an x86-64 EFI application"
/usr/bin/file "$bcd" | grep -Fq "MS Windows registry file" ||
  fail "Windows BCD is not a readable registry hive"
verify_source_config "$source_config"

printf '\n=== audited source ===\n'
printf 'Live OpenCore: /dev/%s on %s (%s)\n' \
  "$source_device" "$source_whole_disk" "$source_parent_model"
printf 'Candidate target: /dev/%s on %s (%s)\n' \
  "$target_device" "$target_whole_disk" "$target_parent_model"
printf 'Windows loader SHA-256: %s\n' \
  "$(shasum -a 256 "$primary_loader" | awk '{ print $1 }')"

if [ -e "$target_oc" ]; then
  [ -f "$target_marker" ] ||
    fail "target EFI/OC exists without the managed candidate marker"
  [ "$(cat "$target_marker")" = "optiplex-3040-monterey-native-v1" ] ||
    fail "target candidate marker has unexpected contents"
  [ -f "$target_oc/OpenCore.efi" ] ||
    fail "target candidate OpenCore.efi is missing"
  cmp -s "$source_oc/OpenCore.efi" "$target_oc/OpenCore.efi" ||
    fail "target candidate uses a different OpenCore.efi"
  verify_candidate_config "$target_config"
  printf 'Native Monterey candidate: staged and validated\n'
  printf 'Candidate loader: %s\n' "$target_oc/OpenCore.efi"
  printf 'No Windows loader, BCD, live EFI, partition, or firmware variable changed.\n'
  exit 0
fi

printf 'Native Monterey candidate: not staged\n'
if [ "$mode" = "audit" ]; then
  printf 'No Windows loader, BCD, live EFI, partition, or firmware variable changed.\n'
  exit 0
fi

[ "$confirmation" = "$CONFIRMATION" ] ||
  fail "apply requires --confirm $CONFIRMATION"

timestamp=$(date -u '+%Y%m%dT%H%M%SZ')
backup_root="$HOME/Documents/OptiPlex-3040-Boot-Backups/$timestamp-monterey-native"
mkdir -p "$backup_root/WIN10-EFI" "$backup_root/MACRECOVERY-EFI"
ditto "$target_efi" "$backup_root/WIN10-EFI"
ditto "$source_mount_point/EFI" "$backup_root/MACRECOVERY-EFI"
sudo nvram -xp | tee "$backup_root/nvram-before.xml" >/dev/null
diskutil list > "$backup_root/diskutil-list.txt"
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

candidate_config=$(mktemp "${TMPDIR:-/tmp}/3040-native-config.XXXXXX")
trap 'rm -f "$candidate_config"' EXIT HUP INT TERM
cp "$source_config" "$candidate_config"
native_boot_args=$(
  remove_boot_argument \
    "$(plist_value \
      "$candidate_config" \
      "NVRAM:Add:$APPLE_NVRAM_GUID:boot-args")" \
    "-igfxsklaskbl"
)
plutil -replace \
  "DeviceProperties.Add.$IGPU_KEY.AAPL,ig-platform-id" \
  -data "$SKL_PLATFORM_DATA" \
  "$candidate_config"
plutil -remove \
  "DeviceProperties.Add.$IGPU_KEY.device-id" \
  "$candidate_config"
plutil -replace \
  "NVRAM.Add.$APPLE_NVRAM_GUID.boot-args" \
  -string "$native_boot_args" \
  "$candidate_config"
verify_candidate_config "$candidate_config"

stage_dir="$target_efi/.OC.monterey-native.$$"
target_rw=0
installed=0
rollback() {
  status=$?
  trap - EXIT HUP INT TERM
  if [ "$status" -ne 0 ]; then
    printf 'Candidate staging failed; removing only the incomplete copy.\n' >&2
    if [ "$target_rw" -eq 0 ]; then
      if mount_read_write "$target_device"; then
        target_rw=1
      fi
    fi
    sudo rm -rf "$stage_dir"
    if [ "$installed" -eq 1 ]; then
      sudo rm -rf "$target_oc"
    fi
    sync
    mount_read_only "$target_device" || true
  fi
  rm -f "$candidate_config"
  exit "$status"
}
trap rollback EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mount_read_write "$target_device" ||
  fail "$target_device did not mount read-write"
target_rw=1
inspect_partition \
  "$target_device" \
  "$TARGET_VOLUME_NAME" \
  "$TARGET_MIN_BYTES" \
  "$TARGET_MAX_BYTES" \
  "samsung" \
  target
target_efi="$target_mount_point/EFI"
target_oc="$target_efi/OC"
stage_dir="$target_efi/.OC.monterey-native.$$"
primary_loader="$target_efi/Microsoft/Boot/bootmgfw.efi"
fallback_loader="$target_efi/Boot/bootx64.efi"
[ ! -e "$target_oc" ] || fail "target EFI/OC appeared during staging"

sudo ditto "$source_oc" "$stage_dir"
sudo cp "$candidate_config" "$stage_dir/config.plist"
printf 'optiplex-3040-monterey-native-v1\n' |
  sudo tee "$stage_dir/$MARKER_NAME" >/dev/null
verify_candidate_config "$stage_dir/config.plist"
cmp -s "$source_oc/OpenCore.efi" "$stage_dir/OpenCore.efi" ||
  fail "staged OpenCore.efi differs from the source"
sudo mv "$stage_dir" "$target_oc"
installed=1
sync

verify_candidate_config "$target_oc/config.plist"
cmp -s "$primary_loader" "$fallback_loader" ||
  fail "Windows loaders changed while staging the candidate"
mount_read_only "$target_device" ||
  fail "$target_device did not remount read-only"
target_rw=0

installed=0
rm -f "$candidate_config"
trap - EXIT HUP INT TERM

printf '\nNative Monterey graphics candidate staged and verified.\n'
printf 'Backup: %s\n' "$backup_root"
printf 'Candidate loader: %s\n' "$target_oc/OpenCore.efi"
printf 'The live OpenCore and both Windows loaders remain unchanged.\n'
printf 'The candidate is not a default and no firmware variable was changed.\n'
printf 'Audit and expose it with arm-optiplex-3040-monterey-native-picker.sh.\n'
printf 'Do not assume bless --nextonly works on this OpenRuntime configuration.\n'
