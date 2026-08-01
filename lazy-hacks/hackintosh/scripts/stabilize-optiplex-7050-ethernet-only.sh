#!/bin/bash

set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

readonly APPLY_CONFIRMATION="STABILIZE-OPTIPLEX-7050"
readonly CLEAN_CONFIRMATION="RECLAIM-OPTIPLEX-7050-GENERATED-DATA"
readonly CONFIG_FILE="$HOME/.config/optiplex-7050-ethernet-stability/environment"
readonly STATE_DIR="$HOME/.local/state/optiplex-7050-ethernet-stability"
readonly SNAPSHOT_DIR="$STATE_DIR/preferences-before-apply"
GUI_DOMAIN="gui/$(id -u)"
readonly GUI_DOMAIN
readonly -a DISABLED_LABELS=(
  com.apple.FileProvider
  com.apple.bird
  com.apple.rapportd
  com.apple.sharingd
  com.apple.bluetoothuserd
)

mode="${1:-audit}"
confirmation="${2:-}"
expected_ethernet_mac="${OPTIPLEX_7050_ETHERNET_MAC:-}"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

load_machine_config() {
  local configured_mac

  if [ -z "$expected_ethernet_mac" ] && [ -r "$CONFIG_FILE" ]; then
    configured_mac=$(
      awk -F= '
        $1 == "OPTIPLEX_7050_ETHERNET_MAC" {
          print tolower($2)
          exit
        }
      ' "$CONFIG_FILE"
    )
    expected_ethernet_mac="$configured_mac"
  fi
  case "$expected_ethernet_mac" in
    [0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]) ;;
    *) fail "set OPTIPLEX_7050_ETHERNET_MAC or create $CONFIG_FILE" ;;
  esac
}

machine_guard() {
  local ethernet_mac

  [ "$(uname -s)" = Darwin ] || fail "run this script on macOS"
  [ "$(id -u)" -ne 0 ] || fail "run as the logged-in desktop user, not root"
  ethernet_mac=$(
    ifconfig en0 2>/dev/null |
      awk '/^[[:space:]]*ether / { print tolower($2); exit }'
  )
  [ "$ethernet_mac" = "$expected_ethernet_mac" ] ||
    fail "configured 7050 Ethernet identity does not match en0"
  if networksetup -listallhardwareports 2>/dev/null |
    grep -q '^Hardware Port: Wi-Fi$'; then
    fail "a Wi-Fi hardware port is present; this Ethernet-only patch is not appropriate"
  fi
  if ! ifconfig en0 2>/dev/null | grep -q 'status: active'; then
    fail "Ethernet en0 is not active"
  fi
}

preference_value() {
  local scope="$1"
  local domain="$2"
  local key="$3"

  if [ "$scope" = current-host ]; then
    defaults -currentHost read "$domain" "$key" 2>/dev/null
  else
    defaults read "$domain" "$key" 2>/dev/null
  fi
}

snapshot_preference() {
  local scope="$1"
  local domain="$2"
  local key="$3"
  local name="$4"
  local type="$5"
  local value

  if [ -e "$SNAPSHOT_DIR/$name" ]; then
    return
  fi
  if value=$(preference_value "$scope" "$domain" "$key"); then
    printf 'present\n%s\n%s\n%s\n%s\n%s\n' \
      "$scope" "$domain" "$key" "$type" "$value" > "$SNAPSHOT_DIR/$name"
  else
    printf 'absent\n%s\n%s\n%s\n%s\n' \
      "$scope" "$domain" "$key" "$type" > "$SNAPSHOT_DIR/$name"
  fi
}

restore_preference() {
  local file="$1"
  local status scope domain key type value
  local -a command=(defaults)

  [ -f "$file" ] || return 0
  status=$(sed -n '1p' "$file")
  scope=$(sed -n '2p' "$file")
  domain=$(sed -n '3p' "$file")
  key=$(sed -n '4p' "$file")
  type=$(sed -n '5p' "$file")
  value=$(sed -n '6p' "$file")
  if [ "$scope" = current-host ]; then
    command+=( -currentHost )
  fi
  if [ "$status" = absent ]; then
    "${command[@]}" delete "$domain" "$key" 2>/dev/null || true
  elif [ "$type" = bool ]; then
    "${command[@]}" write "$domain" "$key" -bool "$value"
  else
    "${command[@]}" write "$domain" "$key" -string "$value"
  fi
}

label_disabled() {
  local label="$1"

  launchctl print-disabled "$GUI_DOMAIN" 2>/dev/null |
    awk -v label="$label" '
      index($0, "\"" label "\"") {
        if ($0 ~ /=> (true|disabled)/) disabled = 1
      }
      END { exit !disabled }
    '
}

snapshot_state() {
  local label

  mkdir -p "$SNAPSHOT_DIR"
  snapshot_preference normal com.apple.loginwindow \
    TALLogoutSavesState loginwindow-save-state bool
  snapshot_preference normal com.apple.loginwindow \
    LoginwindowLaunchesRelaunchApps loginwindow-relaunch-apps bool
  snapshot_preference normal NSGlobalDomain \
    NSQuitAlwaysKeepsWindows keep-windows bool
  snapshot_preference current-host com.apple.coreservices.useractivityd \
    ActivityAdvertisingAllowed handoff-advertising bool
  snapshot_preference current-host com.apple.coreservices.useractivityd \
    ActivityReceivingAllowed handoff-receiving bool
  snapshot_preference normal com.apple.NetworkBrowser \
    DisableAirDrop disable-airdrop bool
  snapshot_preference normal com.apple.sharingd \
    DiscoverableMode sharing-discoverable string

  for label in "${DISABLED_LABELS[@]}"; do
    if [ -e "$SNAPSHOT_DIR/launchctl-$label" ]; then
      continue
    fi
    if label_disabled "$label"; then
      printf 'disabled\n' > "$SNAPSHOT_DIR/launchctl-$label"
    else
      printf 'enabled\n' > "$SNAPSHOT_DIR/launchctl-$label"
    fi
  done
  date '+%Y-%m-%d %H:%M:%S%z' > "$STATE_DIR/applied-at"
}

print_bool_preference() {
  local label="$1"
  local scope="$2"
  local domain="$3"
  local key="$4"
  local value

  value=$(preference_value "$scope" "$domain" "$key" || printf unset)
  printf '%-34s %s\n' "$label" "$value"
}

log_churn() {
  /usr/bin/log show \
    --last 60s \
    --style compact \
    --info \
    --predicate \
    'process == "airportd" OR process == "rapportd" OR process == "sharingd"' \
    2>/dev/null |
    awk '
      NR > 1 {
        process = $4
        sub(/\[.*/, "", process)
        if (process ~ /^(airportd|rapportd|sharingd)$/)
          count[process]++
      }
      END {
        printf "airportd=%d rapportd=%d sharingd=%d\n", \
          count["airportd"] + 0, count["rapportd"] + 0, \
          count["sharingd"] + 0
      }
    '
}

audit() {
  local label state

  printf 'Machine: OptiPlex 7050 Ethernet-only profile\n'
  printf 'Ethernet identity: verified on en0\n'
  printf 'Uptime: '
  uptime
  printf '\nFree space:\n'
  df -h /System/Volumes/Data 2>/dev/null || df -h /

  printf '\nDisabled per-user cloud/Continuity jobs:\n'
  for label in "${DISABLED_LABELS[@]}"; do
    if label_disabled "$label"; then
      state=disabled
    elif launchctl print "$GUI_DOMAIN/$label" >/dev/null 2>&1; then
      state=running
    else
      state=enabled-not-running
    fi
    printf '%-34s %s\n' "$label" "$state"
  done

  printf '\nLogin and Continuity preferences:\n'
  print_bool_preference 'save logout state' normal \
    com.apple.loginwindow TALLogoutSavesState
  print_bool_preference 'relaunch apps after login' normal \
    com.apple.loginwindow LoginwindowLaunchesRelaunchApps
  print_bool_preference 'keep application windows' normal \
    NSGlobalDomain NSQuitAlwaysKeepsWindows
  print_bool_preference 'Handoff advertising' current-host \
    com.apple.coreservices.useractivityd ActivityAdvertisingAllowed
  print_bool_preference 'Handoff receiving' current-host \
    com.apple.coreservices.useractivityd ActivityReceivingAllowed
  print_bool_preference 'AirDrop disabled' normal \
    com.apple.NetworkBrowser DisableAirDrop

  printf '\nRecent service log volume (60 seconds):\n'
  log_churn
  printf '\nRemote access:\n'
  for port in 22 5900 3283; do
    if netstat -an -p tcp 2>/dev/null |
      awk -v port="$port" '
        $4 ~ "[.:]" port "$" && $6 == "LISTEN" { found = 1 }
        END { exit !found }
      '; then
      state=listening
    else
      state=closed
    fi
    printf 'tcp/%-5s %s\n' "$port" "$state"
  done
  printf 'UU processes: '
  pgrep -lf 'UURemote(Daemon|Service|Server)?($| )' 2>/dev/null |
    wc -l |
    tr -d ' '
}

apply_patch() {
  local label

  [ "$confirmation" = "$APPLY_CONFIRMATION" ] ||
    fail "apply requires literal confirmation $APPLY_CONFIRMATION"
  snapshot_state

  defaults write com.apple.loginwindow TALLogoutSavesState -bool false
  defaults write com.apple.loginwindow LoginwindowLaunchesRelaunchApps -bool false
  defaults write NSGlobalDomain NSQuitAlwaysKeepsWindows -bool false
  defaults -currentHost write com.apple.coreservices.useractivityd \
    ActivityAdvertisingAllowed -bool false
  defaults -currentHost write com.apple.coreservices.useractivityd \
    ActivityReceivingAllowed -bool false
  defaults write com.apple.NetworkBrowser DisableAirDrop -bool true
  defaults write com.apple.sharingd DiscoverableMode -string Off

  for label in "${DISABLED_LABELS[@]}"; do
    launchctl disable "$GUI_DOMAIN/$label"
    launchctl bootout "$GUI_DOMAIN/$label" 2>/dev/null || true
  done
  killall cfprefsd 2>/dev/null || true
  printf 'Applied the reversible Ethernet-only service and login policy.\n'
}

clear_directory_contents() {
  local path="$1"
  local before_kb after_kb

  [ -d "$path" ] || return 0
  before_kb=$(du -sk "$path" 2>/dev/null | awk '{ print $1 + 0 }')
  find "$path" -mindepth 1 -depth -delete
  after_kb=$(du -sk "$path" 2>/dev/null | awk '{ print $1 + 0 }')
  printf 'Reclaimed %d MiB from %s\n' \
    "$(((before_kb - after_kb) / 1024))" "$path"
}

quit_if_running() {
  local application="$1"
  local process_name="$2"

  if ! pgrep -x "$process_name" >/dev/null 2>&1; then
    return 0
  fi
  osascript -e "tell application \"$application\" to quit" \
    >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do
    pgrep -x "$process_name" >/dev/null 2>&1 || return 0
    sleep 0.5
  done
  fail "$application did not quit cleanly; resolve its prompt and rerun cleanup"
}

cleanup_generated_data() {
  [ "$confirmation" = "$CLEAN_CONFIRMATION" ] ||
    fail "cleanup requires literal confirmation $CLEAN_CONFIRMATION"

  quit_if_running ChatGPT ChatGPT
  quit_if_running Xcode Xcode
  quit_if_running Safari Safari
  xcrun simctl shutdown all >/dev/null 2>&1 || true
  xcrun simctl delete unavailable >/dev/null 2>&1 || true

  clear_directory_contents "$HOME/Library/Developer/Xcode/DerivedData"
  clear_directory_contents "$HOME/Library/Developer/Xcode/iOS DeviceSupport"
  clear_directory_contents "$HOME/Library/Caches/com.openai.codex"
  clear_directory_contents "$HOME/Library/Caches/com.apple.dt.Xcode"
  clear_directory_contents "$HOME/Library/Caches/com.apple.dt.xcodebuild"
  clear_directory_contents "$HOME/Library/Caches/Homebrew"
  clear_directory_contents "$HOME/Library/Caches/puccinialin"
  clear_directory_contents "$HOME/Library/Caches/pip"
  clear_directory_contents "$HOME/Library/Caches/GlassAgent"
  clear_directory_contents "$HOME/.cache/codex-runtimes"
  clear_directory_contents "$HOME/.gradle/caches"
  clear_directory_contents "$HOME/Library/Caches/CocoaPods"
  clear_directory_contents "$HOME/Library/Caches/org.swift.swiftpm"
  clear_directory_contents "$HOME/Library/Caches/CloudKit"
  clear_directory_contents "$HOME/Library/Logs/GlassAgent"
  printf 'Preserved projects, Codex state, UU data, simulator runtimes, and APFS volumes.\n'
}

rollback() {
  local file label prior

  [ -d "$SNAPSHOT_DIR" ] || fail "no pre-apply snapshot is available"
  for file in \
    "$SNAPSHOT_DIR/loginwindow-save-state" \
    "$SNAPSHOT_DIR/loginwindow-relaunch-apps" \
    "$SNAPSHOT_DIR/keep-windows" \
    "$SNAPSHOT_DIR/handoff-advertising" \
    "$SNAPSHOT_DIR/handoff-receiving" \
    "$SNAPSHOT_DIR/disable-airdrop" \
    "$SNAPSHOT_DIR/sharing-discoverable"; do
    restore_preference "$file"
  done

  for label in "${DISABLED_LABELS[@]}"; do
    prior=$(sed -n '1p' "$SNAPSHOT_DIR/launchctl-$label" 2>/dev/null || true)
    if [ "$prior" = disabled ]; then
      launchctl disable "$GUI_DOMAIN/$label"
    else
      launchctl enable "$GUI_DOMAIN/$label"
      launchctl kickstart "$GUI_DOMAIN/$label" 2>/dev/null || true
    fi
  done
  killall cfprefsd 2>/dev/null || true
  printf 'Restored the captured pre-apply preferences and launchd states.\n'
}

load_machine_config
machine_guard
case "$mode" in
  audit)
    audit
    ;;
  apply)
    apply_patch
    audit
    ;;
  cleanup)
    cleanup_generated_data
    audit
    ;;
  rollback)
    rollback
    audit
    ;;
  *)
    fail "mode must be audit, apply, cleanup, or rollback"
    ;;
esac
