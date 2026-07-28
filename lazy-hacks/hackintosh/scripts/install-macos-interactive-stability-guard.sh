#!/bin/bash

set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

readonly LABEL="com.lachlan.macos-interactive-stability-guard"
readonly EXPECTED_UU_TEAM_ID="PU9BNSBJW7"
readonly HELPER_DIR="$HOME/.local/libexec"
readonly HELPER="$HELPER_DIR/macos-interactive-stability-guard"
readonly PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
mode="${1:-install}"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

audit() {
  printf 'LaunchAgent: '
  if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    printf 'loaded\n'
  else
    printf 'not loaded\n'
  fi

  printf 'Helper: %s\n' "$([ -x "$HELPER" ] && printf installed || printf missing)"
  printf 'Configuration: %s\n' "$([ -f "$PLIST" ] && printf installed || printf missing)"
  printf '\nBackground process priorities:\n'
  ps -axo pid=,ni=,%cpu=,etime=,comm= |
    awk '
      /bird|fileproviderd|mediaanalysisd|photoanalysisd|cloudphotod|photolibraryd/ {
        print
      }
    ' ||
    true
  printf '\nRecent guard log:\n'
  tail -n 40 "$HOME/Library/Logs/MacInteractiveStabilityGuard.log" \
    2>/dev/null ||
    printf '(no log yet)\n'
}

[ "$(uname -s)" = "Darwin" ] || fail "run this script on macOS"
[ "$(id -u)" -ne 0 ] || fail "run as the logged-in desktop user, not root"
case "$mode" in
  install | audit | uninstall) ;;
  *) fail "mode must be install, audit, or uninstall" ;;
esac

if [ "$mode" = "audit" ]; then
  audit
  exit 0
fi

gui_domain="gui/$(id -u)"
if [ "$mode" = "uninstall" ]; then
  launchctl bootout "$gui_domain/$LABEL" 2>/dev/null || true
  rm -f "$PLIST" "$HELPER"
  printf 'Removed %s.\n' "$LABEL"
  exit 0
fi

if [ -d /Applications/UURemote.app ]; then
  codesign --verify --deep --strict /Applications/UURemote.app
  team_id=$(
    codesign -dv --verbose=2 /Applications/UURemote.app 2>&1 |
      sed -n 's/^TeamIdentifier=//p' |
      head -n 1
  )
  [ "$team_id" = "$EXPECTED_UU_TEAM_ID" ] ||
    fail "UU Remote has unexpected Team ID: $team_id"
fi

mkdir -p "$HELPER_DIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cat > "$HELPER" <<'HELPER'
#!/bin/bash

set -u
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

readonly LABEL="com.lachlan.macos-interactive-stability-guard"
readonly LOG="$HOME/Library/Logs/MacInteractiveStabilityGuard.log"
readonly STATE_DIR="$HOME/Library/Application Support/$LABEL"
readonly UU_MISS_FILE="$STATE_DIR/uu-misses"
readonly MAX_LOG_BYTES=1048576
readonly MIN_FREE_GB=25

mkdir -p "$STATE_DIR" "$(dirname "$LOG")"
if [ -f "$LOG" ] &&
   [ "$(stat -f '%z' "$LOG" 2>/dev/null || printf 0)" -gt \
     "$MAX_LOG_BYTES" ]; then
  mv -f "$LOG" "${LOG}.previous"
fi

timestamp=$(date '+%Y-%m-%d %H:%M:%S%z')
log() {
  printf '%s %s\n' "$timestamp" "$*" >> "$LOG"
}

for name in \
  bird \
  fileproviderd \
  mediaanalysisd \
  photoanalysisd \
  cloudphotod \
  photolibraryd; do
  pgrep -x "$name" 2>/dev/null |
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      renice 19 -p "$pid" >/dev/null 2>&1 || true
      /usr/sbin/taskpolicy \
        -b \
        -t 5 \
        -l 5 \
        -p "$pid" \
        >/dev/null 2>&1 ||
        true
    done
done

free_kb=$(
  df -k /System/Volumes/Data 2>/dev/null |
    awk 'NR == 2 { print $4 }'
)
case "${free_kb:-}" in
  '' | *[!0-9]*) free_gb=unknown ;;
  *) free_gb=$((free_kb / 1024 / 1024)) ;;
esac

uu_count=$(
  ps -axo uid=,comm= |
    awk -v uid="$(id -u)" '
      $1 == uid &&
      ($2 ~ /\/UURemoteService$/ || $2 ~ /\/UURemoteServer$/) {
        count++
      }
      END {
        print count + 0
      }
    '
)

if [ "$uu_count" -eq 0 ] && [ -d /Applications/UURemote.app ]; then
  misses=$(cat "$UU_MISS_FILE" 2>/dev/null || printf 0)
  case "$misses" in
    '' | *[!0-9]*) misses=0 ;;
  esac
  misses=$((misses + 1))
  printf '%s\n' "$misses" > "$UU_MISS_FILE"
  if [ "$misses" -ge 3 ]; then
    launchctl kickstart -k \
      "gui/$(id -u)/com.netease.uuremote.agent" \
      >/dev/null 2>&1 ||
      true
    printf '0\n' > "$UU_MISS_FILE"
    log "action=kickstart-uuremote reason=missing-three-checks"
  fi
else
  printf '0\n' > "$UU_MISS_FILE"
fi

windowserver=down
pgrep -x WindowServer >/dev/null 2>&1 && windowserver=up
vnc=down
netstat -an -p tcp 2>/dev/null |
  awk '$4 ~ /\.5900$/ && $6 == "LISTEN" { found = 1 } END { exit !found }' &&
  vnc=up

top_background=$(
  ps -axo %cpu=,comm= |
    awk '
      /bird|fileproviderd|mediaanalysisd|photoanalysisd|cloudphotod|photolibraryd/ {
        if ($1 + 0 > max) {
          max = $1 + 0
          name = $2
        }
      }
      END {
        if (name != "") {
          printf "%s:%.1f", name, max
        } else {
          printf "none:0.0"
        }
      }
    '
)

log \
  "free_gb=$free_gb windowserver=$windowserver vnc=$vnc uu_processes=$uu_count background_top=$top_background"
if [ "$free_gb" != unknown ] && [ "$free_gb" -lt "$MIN_FREE_GB" ]; then
  log "warning=low-free-space threshold_gb=$MIN_FREE_GB"
fi
HELPER
chmod 700 "$HELPER"

cat > "$PLIST" <<PLIST
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
  <integer>120</integer>
  <key>ProcessType</key>
  <string>Background</string>
  <key>LowPriorityIO</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>30</integer>
</dict>
</plist>
PLIST
chmod 600 "$PLIST"
plutil -lint "$PLIST"

launchctl bootout "$gui_domain/$LABEL" 2>/dev/null || true
launchctl bootstrap "$gui_domain" "$PLIST"
launchctl enable "$gui_domain/$LABEL"
launchctl kickstart -k "$gui_domain/$LABEL"
sleep 1
audit
