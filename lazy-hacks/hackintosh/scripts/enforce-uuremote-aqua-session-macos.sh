#!/bin/bash

set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

readonly EXPECTED_TEAM_ID="PU9BNSBJW7"
readonly AGENT_LABEL="com.netease.uuremote.agent"
readonly AGENT_PLIST="/Library/LaunchAgents/com.netease.uuremote.agent.plist"
readonly APP="/Applications/UURemote.app"
readonly CONFIRMATION="UU-AQUA-ONLY"

mode="${1:-audit}"
confirmation="${2:-}"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

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

[ -d "$APP" ] || fail "UU Remote is not installed"
[ -f "$AGENT_PLIST" ] || fail "UU Remote LaunchAgent is missing"
codesign --verify --deep --strict "$APP"
team_id=$(
  codesign -dv --verbose=2 "$APP" 2>&1 |
    sed -n 's/^TeamIdentifier=//p' |
    head -n 1
)
[ "$team_id" = "$EXPECTED_TEAM_ID" ] ||
  fail "UU Remote has unexpected Team ID: $team_id"
[ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$AGENT_PLIST")" = \
  "$AGENT_LABEL" ] || fail "UU Remote LaunchAgent has an unexpected label"

session_types=$(
  /usr/libexec/PlistBuddy \
    -c 'Print :LimitLoadToSessionType' \
    "$AGENT_PLIST"
)
aqua_present=0
loginwindow_present=0
printf '%s\n' "$session_types" | grep -Fq "Aqua" && aqua_present=1
printf '%s\n' "$session_types" | grep -Fq "LoginWindow" &&
  loginwindow_present=1

printf 'UU Remote Team ID: %s\n' "$team_id"
printf 'LaunchAgent session types:\n%s\n' "$session_types"
if ps -axo uid=,command= |
   awk '
     $1 == 0 &&
     ($0 ~ /UURemoteService -agent/ || $0 ~ /UURemoteServer/) {
       found = 1
     }
     END {
       exit !found
     }
   '; then
  printf 'Root loginwindow UU agent: loaded\n'
  root_agent_loaded=1
else
  printf 'Root loginwindow UU agent: not loaded\n'
  root_agent_loaded=0
fi

if [ "$mode" = "audit" ]; then
  if [ "$aqua_present" -ne 1 ] ||
     [ "$loginwindow_present" -ne 0 ] ||
     [ "$root_agent_loaded" -ne 0 ]; then
    fail "UU Remote is not restricted to the visible Aqua console"
  fi
  launchctl print "gui/$(id -u)/$AGENT_LABEL" >/dev/null ||
    fail "the logged-in user's UU agent is not loaded"
  printf 'Audit passed. UU Remote uses only the visible Aqua session.\n'
  exit 0
fi

sudo -v
if [ "$aqua_present" -ne 1 ] || [ "$loginwindow_present" -ne 0 ]; then
  timestamp=$(date -u '+%Y%m%dT%H%M%SZ')
  sudo cp -p \
    "$AGENT_PLIST" \
    "${AGENT_PLIST}.before-aqua-only-${timestamp}"
  sudo plutil \
    -replace LimitLoadToSessionType \
    -json '["Aqua"]' \
    "$AGENT_PLIST"
  sudo plutil -lint "$AGENT_PLIST"
fi

sudo launchctl bootout "gui/0/$AGENT_LABEL" 2>/dev/null || true
sudo launchctl bootout "user/0/$AGENT_LABEL" 2>/dev/null || true
gui_domain="gui/$(id -u)"
launchctl bootout "$gui_domain/$AGENT_LABEL" 2>/dev/null || true
launchctl enable "$gui_domain/$AGENT_LABEL"
if ! launchctl bootstrap "$gui_domain" "$AGENT_PLIST" 2>/dev/null; then
  launchctl kickstart -k "$gui_domain/$AGENT_LABEL"
fi
launchctl print "$gui_domain/$AGENT_LABEL" >/dev/null

printf 'UU Remote is restricted to the logged-in Aqua console.\n'
printf 'No TCC database, account state, or assistance credential was changed.\n'
