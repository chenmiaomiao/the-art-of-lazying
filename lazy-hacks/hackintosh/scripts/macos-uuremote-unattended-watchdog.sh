#!/bin/bash

set -u
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
umask 077

readonly APP="/Applications/UURemote.app"
readonly CLI="$APP/Contents/Helpers/uuyc-cli"
readonly EXPECTED_TEAM_ID="PU9BNSBJW7"
readonly DAEMON_LABEL="com.netease.uuremote.daemon"
readonly DAEMON_PLIST="/Library/LaunchDaemons/${DAEMON_LABEL}.plist"
readonly AGENT_LABEL="com.netease.uuremote.agent"
readonly AGENT_PLIST="/Library/LaunchAgents/${AGENT_LABEL}.plist"
readonly LABEL="com.lachlan.macos-uuremote-unattended"
readonly STATE_DIR="/var/db/$LABEL"
readonly FAILURE_FILE="$STATE_DIR/consecutive-failures"
readonly LAST_STATE_FILE="$STATE_DIR/last-state"
readonly HEARTBEAT_FILE="$STATE_DIR/heartbeat"
readonly LOG="/var/log/macos-uuremote-unattended.log"
readonly MAX_LOG_BYTES=2097152
readonly MIN_BOOT_AGE=60
readonly MISSING_LIMIT=2
readonly UNHEALTHY_LIMIT=5
readonly SIMULATOR_PROCESS_LIMIT=100
readonly LOAD_LIMIT=100

log_event() {
  logger -t macos-uuremote-unattended -- "$*"
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

rotate_log() {
  if [ -f "$LOG" ] &&
     [ "$(stat -f '%z' "$LOG" 2>/dev/null || printf 0)" -gt \
       "$MAX_LOG_BYTES" ]; then
    mv -f "$LOG" "${LOG}.previous"
  fi
}

read_counter() {
  local file="$1"
  local value=0

  if [ -r "$file" ]; then
    read -r value < "$file" || value=0
  fi
  case "$value" in
    '' | *[!0-9]*) value=0 ;;
  esac
  printf '%s\n' "$value"
}

write_counter() {
  local file="$1"
  local value="$2"
  local candidate="${file}.$$"

  printf '%s\n' "$value" > "$candidate"
  mv -f "$candidate" "$file"
}

set_state() {
  local state="$1"
  local message="$2"
  local previous=""
  local candidate="${LAST_STATE_FILE}.$$"

  if [ -r "$LAST_STATE_FILE" ]; then
    read -r previous < "$LAST_STATE_FILE" || previous=""
  fi
  if [ "$state" != "$previous" ]; then
    log_event "state=${state} ${message}"
  fi
  printf '%s\n' "$state" > "$candidate"
  mv -f "$candidate" "$LAST_STATE_FILE"
}

run_with_timeout() {
  local seconds="$1"
  shift

  perl -e '
    use strict;
    use warnings;
    my $seconds = shift @ARGV;
    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
      exec @ARGV;
      exit 127;
    }
    $SIG{ALRM} = sub {
      kill "TERM", $pid;
      select undef, undef, undef, 0.5;
      kill "KILL", $pid;
      waitpid $pid, 0;
      exit 124;
    };
    alarm $seconds;
    waitpid $pid, 0;
    my $status = $?;
    alarm 0;
    exit 128 + ($status & 127) if $status & 127;
    exit $status >> 8;
  ' "$seconds" "$@"
}

verify_uuremote() {
  local team_id

  [ -d "$APP" ] || return 1
  [ -x "$CLI" ] || return 1
  [ -f "$DAEMON_PLIST" ] || return 1
  [ -f "$AGENT_PLIST" ] || return 1
  codesign --verify --deep --strict "$APP" >/dev/null 2>&1 || return 1
  team_id=$(
    codesign -dv --verbose=2 "$APP" 2>&1 |
      sed -n 's/^TeamIdentifier=//p' |
      head -n 1
  )
  [ "$team_id" = "$EXPECTED_TEAM_ID" ] || return 1
  [ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$DAEMON_PLIST")" = \
    "$DAEMON_LABEL" ] || return 1
  [ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$AGENT_PLIST")" = \
    "$AGENT_LABEL" ] || return 1
  /usr/libexec/PlistBuddy \
    -c 'Print :LimitLoadToSessionType' \
    "$AGENT_PLIST" 2>/dev/null |
    grep -Fq Aqua
}

process_ids_for_path() {
  local user_id="$1"
  local pattern="$2"

  pgrep -u "$user_id" -f "$pattern" 2>/dev/null || true
}

established_connection_count() {
  local process_ids="$1"
  local process_id
  local count=0
  local current

  for process_id in $process_ids; do
    current=$(
      lsof -nP -a -p "$process_id" -iTCP -sTCP:ESTABLISHED 2>/dev/null |
        awk 'NR > 1 { count++ } END { print count + 0 }'
    )
    count=$((count + current))
  done
  printf '%s\n' "$count"
}

read_cli_status() {
  local console_user="$1"
  local user_id="$2"
  local home_dir="$3"
  local status_json

  status_json=$(
    run_with_timeout 10 \
      launchctl asuser "$user_id" \
      sudo -u "$console_user" \
      env \
        HOME="$home_dir" \
        USER="$console_user" \
        LOGNAME="$console_user" \
        "$CLI" status 2>/dev/null
  ) || return 1

  cli_network=$(
    printf '%s\n' "$status_json" |
      plutil -extract data.networkStatus raw -o - - 2>/dev/null
  ) || cli_network=unknown
  cli_xpc=$(
    printf '%s\n' "$status_json" |
      plutil -extract data.xpcServiceStatus raw -o - - 2>/dev/null
  ) || cli_xpc=unknown
  cli_logged_in=$(
    printf '%s\n' "$status_json" |
      plutil -extract data.isLoggedIn raw -o - - 2>/dev/null
  ) || cli_logged_in=unknown
  return 0
}

read_cli_active_connections() {
  local console_user="$1"
  local user_id="$2"
  local home_dir="$3"
  local connection_json

  connection_json=$(
    run_with_timeout 10 \
      launchctl asuser "$user_id" \
      sudo -u "$console_user" \
      env \
        HOME="$home_dir" \
        USER="$console_user" \
        LOGNAME="$console_user" \
        "$CLI" device status 2>/dev/null
  ) || return 1

  cli_active_connections=$(
    printf '%s\n' "$connection_json" |
      plutil -extract data.hasActiveConnections raw -o - - 2>/dev/null
  ) || cli_active_connections=unknown
  return 0
}

internet_available() {
  local url

  for url in \
    'https://a56.gdl.netease.com/uuyc_4.33.0.pkg' \
    'https://www.apple.com/library/test/success.html'; do
    if curl --head --fail --silent --max-time 6 \
      --output /dev/null \
      "$url" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

write_heartbeat() {
  local console_user="$1"
  local user_id="$2"
  local boot_age="$3"
  local daemon_pid="$4"
  local agent_pid="$5"
  local server_pid="$6"
  local connection_count="$7"
  local failures="$8"
  local simulator_processes="$9"
  local candidate="${HEARTBEAT_FILE}.$$"
  local data_free_kb
  local load_average

  data_free_kb=$(
    df -k /System/Volumes/Data 2>/dev/null |
      awk 'NR == 2 { print $4 }'
  )
  load_average=$(sysctl -n vm.loadavg 2>/dev/null || printf unknown)

  {
    printf 'time_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'boot_age_seconds=%s\n' "$boot_age"
    printf 'console_user=%s\n' "$console_user"
    printf 'console_uid=%s\n' "$user_id"
    printf 'daemon_pid=%s\n' "$daemon_pid"
    printf 'agent_pid=%s\n' "$agent_pid"
    printf 'server_pid=%s\n' "$server_pid"
    printf 'established_tcp=%s\n' "$connection_count"
    printf 'cli_network=%s\n' "${cli_network:-unknown}"
    printf 'cli_xpc=%s\n' "${cli_xpc:-unknown}"
    printf 'cli_logged_in=%s\n' "${cli_logged_in:-unknown}"
    printf 'consecutive_failures=%s\n' "$failures"
    printf 'simulator_runtime_processes=%s\n' "$simulator_processes"
    printf 'load_average=%s\n' "$load_average"
    printf 'data_free_kb=%s\n' "${data_free_kb:-unknown}"
  } > "$candidate"
  mv -f "$candidate" "$HEARTBEAT_FILE"
}

shutdown_runaway_simulator() {
  local console_user="$1"
  local user_id="$2"
  local simulator_processes="$3"
  local load_one="$4"
  local developer_dir
  local home_dir

  if [ "$simulator_processes" -lt "$SIMULATOR_PROCESS_LIMIT" ]; then
    return 0
  fi
  if ! awk -v load="$load_one" -v limit="$LOAD_LIMIT" \
    'BEGIN { exit !(load >= limit) }'; then
    return 0
  fi

  developer_dir=$(xcode-select -p 2>/dev/null || true)
  [ -d "$developer_dir" ] || {
    log_event "simulator pressure exceeded limits, but Xcode is unavailable"
    return 1
  }
  home_dir=$(dscl . -read "/Users/${console_user}" NFSHomeDirectory 2>/dev/null |
    awk '{ print $2 }')
  [ -n "$home_dir" ] || home_dir="/Users/${console_user}"

  if launchctl asuser "$user_id" \
    sudo -u "$console_user" \
    env \
      HOME="$home_dir" \
      DEVELOPER_DIR="$developer_dir" \
      xcrun simctl shutdown all >/dev/null 2>&1; then
    log_event \
      "shut down runaway Simulator: processes=${simulator_processes} load1=${load_one}"
    return 0
  fi

  log_event \
    "failed to shut down runaway Simulator: processes=${simulator_processes} load1=${load_one}"
  return 1
}

repair_system_daemon() {
  if ! verify_uuremote; then
    log_event "refused system-daemon repair because signature validation failed"
    return 1
  fi

  launchctl enable "system/$DAEMON_LABEL"
  if launchctl print "system/$DAEMON_LABEL" >/dev/null 2>&1; then
    launchctl kickstart -k "system/$DAEMON_LABEL" >/dev/null 2>&1
  else
    launchctl bootstrap system "$DAEMON_PLIST" >/dev/null 2>&1
  fi
}

repair_user_agent() {
  local user_id="$1"

  if ! verify_uuremote; then
    log_event "refused user-agent repair because signature validation failed"
    return 1
  fi

  launchctl enable "gui/${user_id}/$AGENT_LABEL"
  if launchctl print "gui/${user_id}/$AGENT_LABEL" >/dev/null 2>&1; then
    launchctl kickstart -k "gui/${user_id}/$AGENT_LABEL" >/dev/null 2>&1
  else
    launchctl bootstrap "gui/${user_id}" "$AGENT_PLIST" >/dev/null 2>&1
  fi
}

[ "$(id -u)" -eq 0 ] || {
  printf 'Run as root through launchd.\n' >&2
  exit 77
}

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
rotate_log

boot_time=$(
  sysctl -n kern.boottime 2>/dev/null |
    sed -n 's/.*{ sec = \([0-9][0-9]*\),.*/\1/p'
)
now=$(date +%s)
case "$boot_time" in
  '' | *[!0-9]*) boot_age=0 ;;
  *)
    if [ "$boot_time" -gt 0 ] && [ "$boot_time" -le "$now" ]; then
      boot_age=$((now - boot_time))
    else
      boot_age=0
    fi
    ;;
esac

daemon_pids=$(
  process_ids_for_path \
    0 \
    '^/Applications/UURemote\.app/Contents/MacOS/UURemoteDaemon -daemon$'
)
if [ -z "$daemon_pids" ] && [ "$boot_age" -ge 30 ]; then
  if repair_system_daemon; then
    log_event "repaired missing UU system daemon"
    sleep 2
    daemon_pids=$(
      process_ids_for_path \
        0 \
        '^/Applications/UURemote\.app/Contents/MacOS/UURemoteDaemon -daemon$'
    )
  else
    log_event "failed to repair missing UU system daemon"
  fi
fi

console_user=$(stat -f '%Su' /dev/console 2>/dev/null || printf none)
case "$console_user" in
  '' | root | loginwindow | _mbsetupuser | none)
    write_counter "$FAILURE_FILE" 0
    set_state waiting-for-aqua "console_user=${console_user}"
    cli_network=not-available
    cli_xpc=not-available
    cli_logged_in=not-available
    write_heartbeat \
      "$console_user" \
      0 \
      "$boot_age" \
      "${daemon_pids:-none}" \
      none \
      none \
      0 \
      0 \
      0
    exit 0
    ;;
esac

user_id=$(id -u "$console_user" 2>/dev/null || printf 0)
case "$user_id" in
  '' | *[!0-9]* | 0) exit 0 ;;
esac
[ "$user_id" -ge 500 ] || exit 0

home_dir=$(dscl . -read "/Users/${console_user}" NFSHomeDirectory 2>/dev/null |
  awk '{ print $2 }')
[ -n "$home_dir" ] || home_dir="/Users/${console_user}"

if launchctl print "gui/0/$AGENT_LABEL" >/dev/null 2>&1; then
  launchctl bootout "gui/0/$AGENT_LABEL" >/dev/null 2>&1 || true
  log_event "removed stale root loginwindow UU agent after Aqua login"
fi
launchctl bootout "user/0/$AGENT_LABEL" >/dev/null 2>&1 || true

agent_pids=$(
  process_ids_for_path \
    "$user_id" \
    '^/Applications/UURemote\.app/Contents/MacOS/UURemoteService -agent$'
)
server_pids=$(
  process_ids_for_path \
    "$user_id" \
    '^/Applications/UURemote\.app/Contents/Helpers/UURemoteServer$'
)
all_pids=$(printf '%s\n%s\n' "$agent_pids" "$server_pids" | awk 'NF')
connection_count=$(established_connection_count "$all_pids")
failures=$(read_counter "$FAILURE_FILE")
simulator_processes=$(
  pgrep -f '/CoreSimulator/.*/RuntimeRoot/' 2>/dev/null |
    wc -l |
    tr -d ' '
)
load_one=$(
  sysctl -n vm.loadavg 2>/dev/null |
    sed 's/[{}]//g' |
    awk '{ print $1 }'
)
case "$load_one" in
  '' | *[!0-9.]*) load_one=0 ;;
esac

cli_network=unknown
cli_xpc=unknown
cli_logged_in=unknown
read_cli_status "$console_user" "$user_id" "$home_dir" || true

write_heartbeat \
  "$console_user" \
  "$user_id" \
  "$boot_age" \
  "${daemon_pids:-none}" \
  "${agent_pids:-none}" \
  "${server_pids:-none}" \
  "$connection_count" \
  "$failures" \
  "$simulator_processes"

if [ "$boot_age" -lt "$MIN_BOOT_AGE" ]; then
  write_counter "$FAILURE_FILE" 0
  set_state boot-grace "age=${boot_age}s"
  exit 0
fi

shutdown_runaway_simulator \
  "$console_user" \
  "$user_id" \
  "$simulator_processes" \
  "$load_one" || true

if [ -n "$agent_pids" ] &&
   [ -n "$server_pids" ] &&
   [ "$cli_network" = connected ] &&
   [ "$cli_xpc" = running ] &&
   [ "$cli_logged_in" = true ]; then
  write_counter "$FAILURE_FILE" 0
  set_state healthy \
    "agent=${agent_pids} server=${server_pids} network=${cli_network}"
  exit 0
fi

if [ "$cli_logged_in" = false ]; then
  write_counter "$FAILURE_FILE" 0
  set_state account-login-required \
    "UU account is logged out; preserving account state"
  exit 0
fi

failures=$((failures + 1))
write_counter "$FAILURE_FILE" "$failures"

if [ -z "$agent_pids" ] || [ -z "$server_pids" ]; then
  failure_limit=$MISSING_LIMIT
  failure_reason=missing-process
else
  failure_limit=$UNHEALTHY_LIMIT
  failure_reason=cli-unhealthy
fi

cli_active_connections=unknown
read_cli_active_connections "$console_user" "$user_id" "$home_dir" || true
if [ "$cli_active_connections" = true ] || [ "$connection_count" -gt 2 ]; then
  write_counter "$FAILURE_FILE" 0
  set_state active-session-protected \
    "reason=${failure_reason} cli_active=${cli_active_connections} established_tcp=${connection_count}"
  exit 0
fi

if [ "$failures" -lt "$failure_limit" ]; then
  set_state waiting-to-repair \
    "reason=${failure_reason} failures=${failures}/${failure_limit}"
  exit 0
fi

if [ "$failure_reason" = cli-unhealthy ] && ! internet_available; then
  write_counter "$FAILURE_FILE" 0
  set_state internet-unavailable \
    "UU was not restarted because the external network check failed"
  exit 0
fi

if repair_user_agent "$user_id"; then
  write_counter "$FAILURE_FILE" 0
  set_state repaired \
    "restarted UU agent after ${failures} checks reason=${failure_reason}"
  exit 0
fi

write_counter "$FAILURE_FILE" 0
set_state repair-failed \
  "could not restart UU agent after ${failures} checks reason=${failure_reason}"
exit 1
