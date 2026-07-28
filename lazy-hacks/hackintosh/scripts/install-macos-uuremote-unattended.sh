#!/bin/bash

set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

readonly LABEL="com.lachlan.macos-uuremote-unattended"
readonly PLIST="/Library/LaunchDaemons/${LABEL}.plist"
readonly HELPER="/usr/local/libexec/macos-uuremote-unattended-watchdog.sh"
readonly LOG="/var/log/macos-uuremote-unattended.log"
readonly STATE_DIR="/var/db/$LABEL"
readonly APP="/Applications/UURemote.app"
readonly CLI="$APP/Contents/Helpers/uuyc-cli"
readonly EXPECTED_TEAM_ID="PU9BNSBJW7"
readonly DAEMON_LABEL="com.netease.uuremote.daemon"
readonly DAEMON_PLIST="/Library/LaunchDaemons/${DAEMON_LABEL}.plist"
readonly AGENT_LABEL="com.netease.uuremote.agent"
readonly AGENT_PLIST="/Library/LaunchAgents/${AGENT_LABEL}.plist"
readonly OLD_LABEL="com.lachlan.optiplex-7050-uuremote-watchdog"
readonly OLD_PLIST="/Library/LaunchDaemons/${OLD_LABEL}.plist"
readonly OLD_HELPER="/usr/local/libexec/optiplex-7050-uuremote-watchdog.sh"
readonly CONFIRMATION="UU-UNATTENDED-STARTUP"
readonly REMOVE_CONFIRMATION="REMOVE-UU-UNATTENDED"

mode="${1:-audit}"
confirmation="${2:-}"
script_dir=$(cd -P -- "$(dirname -- "$0")" && pwd)
source_helper="$script_dir/macos-uuremote-unattended-watchdog.sh"
temporary_plist=""

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [ -n "$temporary_plist" ]; then
    rm -f "$temporary_plist"
  fi
}

trap cleanup EXIT

verify_vendor() {
  local team_id

  [ -d "$APP" ] || fail "UU Remote is not installed"
  [ -x "$CLI" ] || fail "UU Remote CLI is missing"
  [ -f "$DAEMON_PLIST" ] || fail "UU Remote LaunchDaemon is missing"
  [ -f "$AGENT_PLIST" ] || fail "UU Remote LaunchAgent is missing"
  codesign --verify --deep --strict "$APP"
  team_id=$(
    codesign -dv --verbose=2 "$APP" 2>&1 |
      sed -n 's/^TeamIdentifier=//p' |
      head -n 1
  )
  [ "$team_id" = "$EXPECTED_TEAM_ID" ] ||
    fail "UU Remote has unexpected Team ID: $team_id"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$DAEMON_PLIST")" = \
    "$DAEMON_LABEL" ] || fail "UU Remote LaunchDaemon label is unexpected"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$AGENT_PLIST")" = \
    "$AGENT_LABEL" ] || fail "UU Remote LaunchAgent label is unexpected"
  /usr/libexec/PlistBuddy \
    -c 'Print :LimitLoadToSessionType' \
    "$AGENT_PLIST" 2>/dev/null |
    grep -Fq Aqua ||
    fail "UU Remote LaunchAgent does not support the Aqua session"
}

print_cli_field() {
  local json="$1"
  local field="$2"
  local value

  value=$(
    printf '%s\n' "$json" |
      plutil -extract "$field" raw -o - - 2>/dev/null ||
      printf unknown
  )
  printf '%s' "$value"
}

audit() {
  local auto_login
  local cli_json=""
  local console_user
  local filevault
  local user_id

  verify_vendor
  console_user=$(stat -f '%Su' /dev/console 2>/dev/null || printf none)
  auto_login=$(
    defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser \
      2>/dev/null ||
      printf disabled
  )
  filevault=$(fdesetup status 2>/dev/null || printf unknown)
  printf 'console_user=%s\n' "$console_user"
  printf 'auto_login_user=%s\n' "$auto_login"
  printf 'filevault=%s\n' "$filevault"

  printf 'vendor_daemon='
  if launchctl print "system/$DAEMON_LABEL" >/dev/null 2>&1; then
    printf 'loaded\n'
  else
    printf 'missing\n'
  fi

  case "$console_user" in
    '' | root | loginwindow | _mbsetupuser | none)
      printf 'vendor_agent=waiting-for-aqua\n'
      ;;
    *)
      user_id=$(id -u "$console_user")
      printf 'vendor_agent='
      if launchctl print "gui/${user_id}/$AGENT_LABEL" >/dev/null 2>&1; then
        printf 'loaded\n'
      else
        printf 'missing\n'
      fi
      if [ "$console_user" = "$(id -un)" ]; then
        cli_json=$("$CLI" status 2>/dev/null || true)
        printf 'uu_network=%s\n' \
          "$(print_cli_field "$cli_json" data.networkStatus)"
        printf 'uu_xpc=%s\n' \
          "$(print_cli_field "$cli_json" data.xpcServiceStatus)"
        printf 'uu_logged_in=%s\n' \
          "$(print_cli_field "$cli_json" data.isLoggedIn)"
      fi
      ;;
  esac

  printf 'unattended_watchdog='
  if launchctl print "system/$LABEL" >/dev/null 2>&1; then
    printf 'loaded\n'
  else
    printf 'missing\n'
  fi
  printf 'legacy_watchdog='
  if launchctl print "system/$OLD_LABEL" >/dev/null 2>&1; then
    printf 'loaded\n'
  else
    printf 'not-loaded\n'
  fi

  if sudo -n test -r "$STATE_DIR/heartbeat" 2>/dev/null; then
    printf '\n=== heartbeat ===\n'
    sudo -n cat "$STATE_DIR/heartbeat"
    printf '\n=== recent watchdog log ===\n'
    sudo -n tail -n 30 "$LOG" 2>/dev/null || true
  else
    printf 'Run audit after sudo authentication to include heartbeat details.\n'
  fi
}

[ "$(uname -s)" = Darwin ] || fail "run this script on macOS"
[ "$(id -u)" -ne 0 ] || fail "run as the logged-in desktop user, not root"
case "$mode" in
  audit | install | uninstall) ;;
  *) fail "mode must be audit, install, or uninstall" ;;
esac

if [ "$mode" = audit ]; then
  audit
  exit 0
fi

if [ "$mode" = uninstall ]; then
  [ "$confirmation" = "$REMOVE_CONFIRMATION" ] ||
    fail "uninstall requires literal confirmation $REMOVE_CONFIRMATION"
  sudo -v
  sudo launchctl bootout "system/$LABEL" 2>/dev/null || true
  sudo rm -f "$PLIST" "$HELPER"
  printf 'Removed the unattended watchdog. Vendor UU jobs were unchanged.\n'
  exit 0
fi

[ "$confirmation" = "$CONFIRMATION" ] ||
  fail "install requires literal confirmation $CONFIRMATION"
[ -x "$source_helper" ] || fail "companion watchdog script is missing"
verify_vendor

console_user=$(stat -f '%Su' /dev/console 2>/dev/null || printf none)
[ "$console_user" = "$(id -un)" ] ||
  fail "install from the logged-in Aqua console user"
user_id=$(id -u)

sudo -v
timestamp=$(date -u '+%Y%m%dT%H%M%SZ')
backup_dir="/var/backups/macos-uuremote-unattended-${timestamp}"
sudo mkdir -p "$backup_dir"
sudo chmod 700 "$backup_dir"
for existing in "$PLIST" "$HELPER" "$OLD_PLIST" "$OLD_HELPER"; do
  if sudo test -e "$existing"; then
    sudo cp -p "$existing" "$backup_dir/"
  fi
done

temporary_plist=$(mktemp "${TMPDIR:-/tmp}/uuremote-unattended.XXXXXX")
cat > "$temporary_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$HELPER</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>30</integer>
  <key>ProcessType</key>
  <string>Background</string>
  <key>LowPriorityIO</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>15</integer>
  <key>StandardOutPath</key>
  <string>$LOG</string>
  <key>StandardErrorPath</key>
  <string>$LOG</string>
</dict>
</plist>
PLIST
plutil -lint "$temporary_plist"

sudo install -d -o root -g wheel -m 755 /usr/local/libexec
sudo install -o root -g wheel -m 755 "$source_helper" "$HELPER"
sudo install -o root -g wheel -m 644 "$temporary_plist" "$PLIST"

sudo launchctl bootout "system/$LABEL" 2>/dev/null || true
sudo launchctl enable "system/$LABEL"
sudo launchctl bootstrap system "$PLIST"
sudo launchctl print "system/$LABEL" >/dev/null

sudo launchctl enable "system/$DAEMON_LABEL"
if ! sudo launchctl print "system/$DAEMON_LABEL" >/dev/null 2>&1; then
  sudo launchctl bootstrap system "$DAEMON_PLIST"
fi
launchctl enable "gui/${user_id}/$AGENT_LABEL"
if ! launchctl print "gui/${user_id}/$AGENT_LABEL" >/dev/null 2>&1; then
  launchctl bootstrap "gui/${user_id}" "$AGENT_PLIST"
fi

if sudo launchctl print "system/$OLD_LABEL" >/dev/null 2>&1; then
  sudo launchctl bootout "system/$OLD_LABEL"
fi
sudo rm -f "$OLD_PLIST" "$OLD_HELPER"

sudo launchctl kickstart -k "system/$LABEL"
sleep 3
printf 'Installed the unattended UU startup watchdog.\n'
printf 'Backup of replaced local files: %s\n' "$backup_dir"
printf 'No UU account, token, TCC permission, or vendor plist was changed.\n\n'
audit
