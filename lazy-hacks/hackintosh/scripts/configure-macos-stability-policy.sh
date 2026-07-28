#!/bin/bash

set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

readonly CONFIRMATION="MACOS-STABILITY-POLICY"
mode="${1:-audit}"
confirmation="${2:-}"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

print_state() {
  printf '\n=== power ===\n'
  pmset -g custom
  if sudo -n true 2>/dev/null; then
    sudo -n systemsetup -getrestartfreeze 2>/dev/null || true
    sudo -n systemsetup -getrestartpowerfailure 2>/dev/null || true
  else
    printf 'Restart-after-freeze audit requires administrator access.\n'
  fi

  printf '\n=== software update policy ===\n'
  for key in \
    AutomaticCheckEnabled \
    AutomaticDownload \
    AutomaticallyInstallMacOSUpdates \
    CriticalUpdateInstall \
    ConfigDataInstall; do
    value=$(
      defaults read /Library/Preferences/com.apple.SoftwareUpdate "$key" \
        2>/dev/null ||
        printf unset
    )
    printf '%-38s %s\n' "$key" "$value"
  done

  printf '\n=== update staging and free space ===\n'
  du -shx /System/Volumes/Update /Library/Updates 2>/dev/null || true
  diskutil info /System/Volumes/Update 2>/dev/null |
    grep -E 'Device Identifier|Volume Name|Volume Used Space' ||
    true
  df -h /System/Volumes/Data 2>/dev/null || df -h /
}

[ "$(uname -s)" = "Darwin" ] || fail "run this script on macOS"
[ "$(id -u)" -ne 0 ] || fail "run as the logged-in desktop user, not root"
case "$mode" in
  audit | apply) ;;
  *) fail "mode must be audit or apply" ;;
esac

if [ "$mode" = "audit" ]; then
  print_state
  exit 0
fi

[ "$confirmation" = "$CONFIRMATION" ] ||
  fail "apply requires literal confirmation $CONFIRMATION"

sudo -v
sudo pmset -a \
  sleep 0 \
  disksleep 0 \
  displaysleep 0 \
  powernap 0 \
  standby 0 \
  autopoweroff 0 \
  womp 1 \
  tcpkeepalive 1 \
  autorestart 1
restart_freeze=$(sudo systemsetup -getrestartfreeze 2>/dev/null || true)
case "$restart_freeze" in
  *On) ;;
  *) sudo systemsetup -setrestartfreeze on >/dev/null ;;
esac
restart_power=$(sudo systemsetup -getrestartpowerfailure 2>/dev/null || true)
case "$restart_power" in
  *On) ;;
  *) sudo systemsetup -setrestartpowerfailure on >/dev/null ;;
esac

update_domain="/Library/Preferences/com.apple.SoftwareUpdate"
sudo defaults write "$update_domain" AutomaticCheckEnabled -bool true
sudo defaults write "$update_domain" AutomaticDownload -bool false
sudo defaults write \
  "$update_domain" \
  AutomaticallyInstallMacOSUpdates \
  -bool false
sudo defaults write "$update_domain" CriticalUpdateInstall -bool true
sudo defaults write "$update_domain" ConfigDataInstall -bool true

print_state
printf '\nPolicy applied. Major macOS downloads and installs require a user action.\n'
printf 'Security data and critical system files remain enabled.\n'
printf 'Existing staged update data was reported but not deleted.\n'
