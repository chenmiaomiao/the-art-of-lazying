#!/bin/bash

set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

readonly EXPECTED_MODEL="Micron 1100 SATA 512GB"
readonly EXPECTED_DISK_BYTES="512110190592"
readonly EXPECTED_EFI_BYTES="1076887552"
readonly EXPECTED_OPENCORE_SHA256="8e83a3dd984a4196c1fd9e40d75a6550111a959e44c0668bd9e08098bf0a1ae6"
readonly EXPECTED_OCVALIDATE_SHA256="bcaf32c0615cd17e31f8e61be4e0485e9bd0e6a9196433f4c1596380af0dc18f"
readonly CURRENT_CONFIG_SHA256="87ab79bdc1deb9ded01787223e4c31e40e772af53fe35c617e27daf1556d86b2"
readonly PATCHED_CONFIG_SHA256="54ce4f3b9652d934e2b650015d6c8a6585bb0c6729889ba56aa7a72efd519c8b"
readonly CONFIRMATION="ENABLE-TRIM-OPTIPLEX-7050"

mode="${1:-audit}"
ocvalidate="${2:-$HOME/Downloads/ocvalidate-1.0.7}"
confirmation="${3:-}"
mounted_here=0
mount_point=""
rollback_source=""

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

sha256() {
  shasum -a 256 "$1" | awk '{ print $1 }'
}

unmount_efi() {
  if [ "$mounted_here" -eq 1 ]; then
    sudo diskutil unmount disk0s4 >/dev/null 2>&1 || true
  fi
}

restore_on_failure() {
  local status=$?

  trap - EXIT
  if [ "$status" -ne 0 ] &&
     [ -n "$rollback_source" ] &&
     [ -n "$mount_point" ] &&
     [ -f "$rollback_source" ]; then
    sudo cp -p "$rollback_source" "$mount_point/EFI/OC/config.plist"
    printf 'Restored the pre-change config after a failed validation.\n' >&2
  fi
  unmount_efi
  exit "$status"
}

trap restore_on_failure EXIT

[ "$(uname -s)" = "Darwin" ] || fail "run this script on macOS"
[ "$(id -u)" -ne 0 ] || fail "run as the logged-in desktop user, not root"
case "$mode" in
  audit | apply) ;;
  *) fail "mode must be audit or apply" ;;
esac
if [ "$mode" = "apply" ]; then
  [ "$confirmation" = "$CONFIRMATION" ] ||
    fail "apply requires literal confirmation $CONFIRMATION"
fi

[ -x "$ocvalidate" ] || fail "matching OpenCore 1.0.7 ocvalidate is missing"
[ "$(sha256 "$ocvalidate")" = "$EXPECTED_OCVALIDATE_SHA256" ] ||
  fail "ocvalidate does not match the reviewed OpenCore 1.0.7 release"

disk_info=$(diskutil info disk0)
printf '%s\n' "$disk_info" | grep -Fq "$EXPECTED_MODEL" ||
  fail "disk0 is not the reviewed Micron 1100"
printf '%s\n' "$disk_info" | grep -Fq "($EXPECTED_DISK_BYTES Bytes)" ||
  fail "disk0 has unexpected geometry"

efi_info=$(diskutil info disk0s4)
printf '%s\n' "$efi_info" | grep -Eq 'Partition Type:[[:space:]]+EFI' ||
  fail "disk0s4 is not an EFI partition"
printf '%s\n' "$efi_info" | grep -Fq "($EXPECTED_EFI_BYTES Bytes)" ||
  fail "disk0s4 has unexpected geometry"

sudo -v
existing_mount=$(
  printf '%s\n' "$efi_info" |
    awk -F: '
      /Mount Point/ {
        sub(/^[[:space:]]+/, "", $2)
        print $2
      }
    '
)
if [ -n "$existing_mount" ] && [ "$existing_mount" != "Not applicable" ]; then
  mount_point="$existing_mount"
else
  if [ "$mode" = "apply" ]; then
    sudo diskutil mount disk0s4 >/dev/null
  else
    sudo diskutil mount readOnly disk0s4 >/dev/null
  fi
  mounted_here=1
  mount_point=$(
    diskutil info disk0s4 |
      awk -F: '
        /Mount Point/ {
          sub(/^[[:space:]]+/, "", $2)
          print $2
        }
      '
  )
fi

config="$mount_point/EFI/OC/config.plist"
opencore="$mount_point/EFI/OC/OpenCore.efi"
[ -f "$config" ] || fail "live OpenCore config is missing"
[ -f "$opencore" ] || fail "live OpenCore binary is missing"
[ "$(sha256 "$opencore")" = "$EXPECTED_OPENCORE_SHA256" ] ||
  fail "live OpenCore is not the reviewed official 1.0.7 binary"

config_sha=$(sha256 "$config")
case "$config_sha" in
  "$CURRENT_CONFIG_SHA256") state=trim-disabled ;;
  "$PATCHED_CONFIG_SHA256") state=trim-candidate-live ;;
  *) fail "live config hash is outside the reviewed transition" ;;
esac

"$ocvalidate" "$config"
trim_state=$(
  /usr/libexec/PlistBuddy \
    -c 'Print :Kernel:Quirks:ThirdPartyDrives' \
    "$config"
)
printf 'OpenCore: official 1.0.7\n'
printf 'Config SHA-256: %s\n' "$config_sha"
printf 'ThirdPartyDrives: %s\n' "$trim_state"
printf 'State: %s\n' "$state"

if [ "$mode" = "audit" ]; then
  exit 0
fi
if [ "$config_sha" = "$PATCHED_CONFIG_SHA256" ]; then
  printf 'The reviewed TRIM config is already live. No change made.\n'
  exit 0
fi
if mount | grep -F " on $mount_point " | grep -Fq "read-only"; then
  fail "EFI is mounted read-only; unmount it and rerun apply"
fi

timestamp=$(date -u '+%Y%m%dT%H%M%SZ')
rollback_source="$mount_point/EFI/OC/config.plist.before-trim-${timestamp}"
sudo cp -p "$config" "$rollback_source"
sudo /usr/libexec/PlistBuddy \
  -c 'Set :Kernel:Quirks:ThirdPartyDrives true' \
  "$config"
"$ocvalidate" "$config"
[ "$(sha256 "$config")" = "$PATCHED_CONFIG_SHA256" ] ||
  fail "patched config does not match the reviewed one-line candidate"

rollback_source=""
printf 'Enabled ThirdPartyDrives in the live config.\n'
printf 'Backup: %s\n' "$mount_point/EFI/OC/config.plist.before-trim-${timestamp}"
printf 'No restart was performed. TRIM changes only after the next boot.\n'
