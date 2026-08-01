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
readonly MAX_LOG_BYTES=1048576
readonly WARN_FREE_GB=25
readonly PRESSURE_FREE_GB=15
readonly EMERGENCY_FREE_GB=8
readonly STATE_DIR="$HOME/.local/state/macos-interactive-stability-guard"
readonly RELIEF_STAMP="$STATE_DIR/generated-data-relief-at"
readonly RELIEF_COOLDOWN_SECONDS=21600

mkdir -p "$STATE_DIR"

mkdir -p "$(dirname "$LOG")"
if [ -f "$LOG" ] &&
   [ "$(stat -f '%z' "$LOG" 2>/dev/null || printf 0)" -gt \
     "$MAX_LOG_BYTES" ]; then
  mv -f "$LOG" "${LOG}.previous"
fi

timestamp=$(date '+%Y-%m-%d %H:%M:%S%z')
log() {
  printf '%s %s\n' "$timestamp" "$*" >> "$LOG"
}

notify_user() {
  local message="$1"

  osascript -e \
    "display notification \"$message\" with title \"Mac stability guard\"" \
    >/dev/null 2>&1 || true
}

shutdown_simulators() {
  local count

  count=$(pgrep -f '/CoreSimulator/.*/RuntimeRoot/' 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -gt 0 ] || return 0
  if xcrun simctl shutdown all >/dev/null 2>&1; then
    log "action=shutdown-simulators processes=$count"
  fi
}

clear_directory_contents() {
  local path="$1"

  [ -d "$path" ] || return 0
  find "$path" -mindepth 1 -depth -delete 2>/dev/null || true
}

relief_is_on_cooldown() {
  local last now

  [ -r "$RELIEF_STAMP" ] || return 1
  read -r last < "$RELIEF_STAMP" || return 1
  case "$last" in
    '' | *[!0-9]*) return 1 ;;
  esac
  now=$(date +%s)
  [ "$((now - last))" -lt "$RELIEF_COOLDOWN_SECONDS" ]
}

reclaim_generated_data() {
  local after_kb before_kb process

  relief_is_on_cooldown && {
    log "action=generated-data-relief-skipped reason=cooldown"
    return 0
  }

  for process in Xcode ChatGPT Codex Safari; do
    pgrep -x "$process" >/dev/null 2>&1 || continue
    osascript -e "tell application \"$process\" to quit" \
      >/dev/null 2>&1 || true
  done
  sleep 10
  shutdown_simulators
  xcrun simctl delete unavailable >/dev/null 2>&1 || true

  before_kb=$(df -k /System/Volumes/Data 2>/dev/null | awk 'NR == 2 { print $4 + 0 }')

  if ! pgrep -x Xcode >/dev/null 2>&1 &&
     ! pgrep -x xcodebuild >/dev/null 2>&1; then
    clear_directory_contents "$HOME/Library/Developer/Xcode/DerivedData"
    clear_directory_contents "$HOME/Library/Developer/Xcode/iOS DeviceSupport"
    clear_directory_contents "$HOME/Library/Caches/com.apple.dt.Xcode"
    clear_directory_contents "$HOME/Library/Caches/com.apple.dt.xcodebuild"
  fi
  if ! pgrep -x ChatGPT >/dev/null 2>&1 &&
     ! pgrep -x Codex >/dev/null 2>&1; then
    clear_directory_contents "$HOME/Library/Caches/com.openai.codex"
  fi
  clear_directory_contents "$HOME/Library/Caches/Homebrew"
  clear_directory_contents "$HOME/Library/Caches/pip"
  clear_directory_contents "$HOME/Library/Caches/puccinialin"
  clear_directory_contents "$HOME/Library/Caches/GlassAgent"
  clear_directory_contents "$HOME/.cache/codex-runtimes"
  clear_directory_contents "$HOME/.gradle/caches"
  clear_directory_contents "$HOME/Library/Caches/CocoaPods"
  clear_directory_contents "$HOME/Library/Caches/org.swift.swiftpm"
  clear_directory_contents "$HOME/Library/Caches/CloudKit"
  clear_directory_contents "$HOME/Library/Logs/GlassAgent"

  after_kb=$(df -k /System/Volumes/Data 2>/dev/null | awk 'NR == 2 { print $4 + 0 }')
  date +%s > "$RELIEF_STAMP"
  log "action=generated-data-relief reclaimed_mib=$(((after_kb - before_kb) / 1024))"
  notify_user "Generated data was reclaimed because free space fell below ${EMERGENCY_FREE_GB} GiB."
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
if [ "$free_gb" != unknown ] && [ "$free_gb" -lt "$WARN_FREE_GB" ]; then
  log "warning=low-free-space threshold_gb=$WARN_FREE_GB"
fi
if [ "$free_gb" != unknown ] && [ "$free_gb" -lt "$PRESSURE_FREE_GB" ]; then
  shutdown_simulators
fi
if [ "$free_gb" != unknown ] && [ "$free_gb" -lt "$EMERGENCY_FREE_GB" ]; then
  reclaim_generated_data
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
sleep 1
launchctl print "$gui_domain/$LABEL" >/dev/null 2>&1 ||
  fail "launchd did not retain $LABEL"
audit
