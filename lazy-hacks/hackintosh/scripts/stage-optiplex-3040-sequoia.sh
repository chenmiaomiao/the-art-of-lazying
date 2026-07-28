#!/bin/bash

set -euo pipefail

readonly DEFAULT_VERSION="15.7.7"
readonly MINIMUM_FREE_KB=$((35 * 1024 * 1024))
readonly APP_PATH="/Applications/Install macOS Sequoia.app"
readonly APPLE_NVRAM_GUID="7C436110-AB2A-4BBB-A880-FE41995C9F82"

mode="${1:-audit}"
version="${SEQUOIA_VERSION:-$DEFAULT_VERSION}"
efi_config="${EFI_CONFIG:-}"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

plist_value() {
  local path="$1"

  /usr/libexec/PlistBuddy -c "Print $path" "$efi_config" 2>/dev/null
}

audit_efi() {
  local boot_args
  local product_name

  [ -n "$efi_config" ] || {
    printf 'EFI_CONFIG is unset; skipped OpenCore audit.\n'
    return 0
  }
  [ -f "$efi_config" ] || fail "OpenCore config is missing: $efi_config"
  plutil -lint "$efi_config"

  product_name=$(plist_value ":PlatformInfo:Generic:SystemProductName")
  [ "$product_name" = "iMac17,1" ] ||
    fail "unexpected OpenCore SystemProductName: $product_name"
  boot_args=$(plist_value ":NVRAM:Add:$APPLE_NVRAM_GUID:boot-args")
  case " $boot_args " in
    *" -no_compat_check "*) ;;
    *) fail "OpenCore boot-args is missing -no_compat_check" ;;
  esac
  case " $boot_args " in
    *" revpatch=sbvmm "*) ;;
    *) fail "OpenCore boot-args is missing revpatch=sbvmm" ;;
  esac
  plist_value ":Kernel:Add" |
    grep -Fq "RestrictEvents.kext" ||
    fail "OpenCore does not enable RestrictEvents.kext"
  plist_value ":Kernel:Add" |
    grep -Fq "WhateverGreen.kext" ||
    fail "OpenCore does not enable WhateverGreen.kext"
  printf 'OpenCore Sequoia compatibility audit passed: %s\n' "$efi_config"
}

[ "$(uname -s)" = "Darwin" ] || fail "run this script on macOS"
[ "$(uname -m)" = "x86_64" ] || fail "expected the Intel OptiPlex installation"
case "$mode" in
  audit|fetch) ;;
  *) fail "mode must be audit or fetch" ;;
esac

current_version=$(sw_vers -productVersion)
free_kb=$(df -k / | awk 'NR == 2 { print $4 }')
case "$free_kb" in
  ''|*[!0-9]*) fail "could not measure free space on the macOS volume" ;;
esac
[ "$free_kb" -ge "$MINIMUM_FREE_KB" ] ||
  fail "keep at least 35 GiB free before staging Sequoia"

printf 'Current macOS: %s\n' "$current_version"
printf 'Free space: %s GiB\n' "$((free_kb / 1024 / 1024))"
audit_efi

if [ "$mode" = "audit" ]; then
  printf 'Audit complete. No installer was downloaded and no upgrade was started.\n'
  exit 0
fi

[ -n "$efi_config" ] ||
  fail "set EFI_CONFIG to the mounted, accepted OpenCore config before fetch"

if [ -d "$APP_PATH" ]; then
  installed_version=$(
    defaults read "$APP_PATH/Contents/Info" CFBundleShortVersionString
  )
  [ "$installed_version" = "$version" ] ||
    fail "$APP_PATH already exists with version $installed_version"
else
  sudo softwareupdate \
    --fetch-full-installer \
    --full-installer-version "$version"
fi

[ -d "$APP_PATH" ] || fail "softwareupdate did not create $APP_PATH"
installed_version=$(
  defaults read "$APP_PATH/Contents/Info" CFBundleShortVersionString
)
[ "$installed_version" = "$version" ] ||
  fail "downloaded installer version is $installed_version, expected $version"
[ -f "$APP_PATH/Contents/SharedSupport/InstallAssistant.pkg" ] ||
  fail "downloaded installer is missing InstallAssistant.pkg"
codesign --verify --deep --strict "$APP_PATH"
spctl --assess --type execute --verbose=2 "$APP_PATH"

status_dir="$HOME/Documents/OptiPlex-3040-Sequoia-Staging"
mkdir -p "$status_dir"
{
  printf 'staged_at_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'current_macos=%s\n' "$current_version"
  printf 'installer_version=%s\n' "$installed_version"
  printf 'installer_path=%s\n' "$APP_PATH"
  printf 'upgrade_started=no\n'
} > "$status_dir/status.txt"

printf 'Sequoia %s is staged and verified. The installer was not opened.\n' \
  "$installed_version"
