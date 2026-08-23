#!/usr/bin/env bash
set -euo pipefail

# Share the newest live XRDP Xorg desktop through a localhost-only x11vnc
# listener. A relay computer must use an SSH tunnel to reach it.

action="${1:-start}"
port="${XRDP_VNC_BRIDGE_PORT:-5922}"
geometry="${XRDP_VNC_GEOMETRY:-1620x1080}"
auto_resize="${XRDP_VNC_AUTO_RESIZE:-1}"
state_dir="${XDG_CACHE_HOME:-$HOME/.cache}/xrdp-vnc-bridge"
pid_file="$state_dir/x11vnc.pid"
display_file="$state_dir/display"
log_file="$state_dir/x11vnc.log"
resize_log="$state_dir/resize.log"
keyboard_helper="$HOME/scripts/set-xrdp-japanese-mac-keyboard.sh"

mkdir -p "$state_dir"

read_pid() {
  if [ -r "$pid_file" ]; then
    tr -cd '0-9' <"$pid_file"
  fi
}

pid_matches_bridge() {
  local pid="$1"
  local cmdline

  [ -n "$pid" ] || return 1
  [ -r "/proc/$pid/cmdline" ] || return 1
  cmdline="$(tr '\0' ' ' <"/proc/$pid/cmdline")"
  [[ "$cmdline" == *"x11vnc"* && "$cmdline" == *"-rfbport $port"* ]]
}

display_from_pid() {
  local pid="$1"
  local cmdline

  [ -r "/proc/$pid/cmdline" ] || return 1
  cmdline="$(tr '\0' ' ' <"/proc/$pid/cmdline")"
  if [[ "$cmdline" =~ -display[[:space:]]+(:[0-9]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

find_bridge_pid() {
  local pid

  while read -r pid; do
    [ -n "$pid" ] || continue
    if pid_matches_bridge "$pid"; then
      printf '%s\n' "$pid"
      return 0
    fi
  done < <(pgrep -u "$(id -u)" -x x11vnc 2>/dev/null || true)

  return 1
}

find_xrdp_display() {
  local line
  local found=""

  while IFS= read -r line; do
    if [[ "$line" =~ Xorg[[:space:]]+(:[0-9]+).*xrdp/xorg\.conf ]]; then
      found="${BASH_REMATCH[1]}"
    fi
  done < <(pgrep -u "$(id -u)" -af '/usr/lib/xorg/Xorg :[0-9]+.*xrdp/xorg.conf' 2>/dev/null || true)

  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

port_is_listening() {
  ss -ltnH | awk -v wanted=":$port" '$4 ~ wanted "$" { found=1 } END { exit !found }'
}

current_geometry() {
  local display="$1"

  DISPLAY="$display" XAUTHORITY="$HOME/.Xauthority" \
    xdpyinfo 2>/dev/null \
    | awk '/dimensions:/ { print $2; exit }'
}

keyring_is_unlocked() {
  local locked

  command -v busctl >/dev/null 2>&1 || return 1
  locked="$(
    busctl --user get-property \
      org.freedesktop.secrets \
      /org/freedesktop/secrets/collection/login \
      org.freedesktop.Secret.Collection \
      Locked 2>/dev/null \
      | awk '{ print $2 }'
  )"
  [ "$locked" = "false" ]
}

restore_keyboard() {
  local display="$1"

  if [ -x "$keyboard_helper" ]; then
    DISPLAY="$display" XAUTHORITY="$HOME/.Xauthority" \
      "$keyboard_helper" >/dev/null 2>&1 \
      || printf 'Warning: could not restore the XRDP Japanese Mac keyboard map.\n' >&2
  fi
}

resize_display() {
  local display="${1:-}"
  local password=""
  local client_pid=""
  local actual=""
  local attempt

  if [[ ! "$geometry" =~ ^[0-9]+x[0-9]+$ ]]; then
    printf 'Invalid XRDP_VNC_GEOMETRY: %s\n' "$geometry" >&2
    return 1
  fi

  if [ -z "$display" ] && [ -r "$display_file" ]; then
    display="$(<"$display_file")"
  fi
  if [ -z "$display" ]; then
    display="$(find_xrdp_display || true)"
  fi
  if [ -z "$display" ]; then
    printf 'No live XRDP Xorg display was found. Connect once with XRDP first.\n' >&2
    return 1
  fi

  actual="$(current_geometry "$display" || true)"
  if [ "$actual" = "$geometry" ]; then
    restore_keyboard "$display"
    printf 'display=%s resolution=%s\n' "$display" "$actual"
    return 0
  fi

  for command in xfreerdp3 xvfb-run secret-tool setsid; do
    if ! command -v "$command" >/dev/null 2>&1; then
      printf 'Cannot resize the XRDP desktop: missing command %s.\n' "$command" >&2
      return 1
    fi
  done

  if ! keyring_is_unlocked; then
    printf 'Cannot resize the XRDP desktop because the login keyring is locked.\n' >&2
    return 1
  fi

  password="$(
    timeout 3 secret-tool lookup \
      application xrdp-vnc-bridge \
      account "$USER" 2>/dev/null \
      || true
  )"
  if [ -z "$password" ]; then
    printf 'No XRDP VNC resize credential is stored in the login keyring.\n' >&2
    return 1
  fi

  : >"$resize_log"
  printf '%s\n' "$password" \
    | setsid xvfb-run -a --server-args="-screen 0 ${geometry}x24" \
        xfreerdp3 \
          /v:127.0.0.1 \
          /u:"$USER" \
          /size:"$geometry" \
          /cert:ignore \
          /from-stdin:force \
          /kbd:layout:0x00000411,type:4 \
          /network:lan \
          /audio-mode:2 \
          -clipboard \
          -themes \
          -wallpaper \
        >"$resize_log" 2>&1 &
  client_pid=$!
  unset password

  for attempt in $(seq 1 100); do
    actual="$(current_geometry "$display" || true)"
    if [ "$actual" = "$geometry" ]; then
      break
    fi
    if ! kill -0 "$client_pid" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done

  if kill -0 "$client_pid" 2>/dev/null; then
    kill -INT -- "-$client_pid" 2>/dev/null || true
    for attempt in $(seq 1 20); do
      kill -0 "$client_pid" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$client_pid" 2>/dev/null; then
      kill -TERM -- "-$client_pid" 2>/dev/null || true
    fi
  fi
  wait "$client_pid" 2>/dev/null || true

  # FreeRDP can replace the XKB map while it reconnects. Restore the known-good
  # Japanese Apple keyboard profile before handing the desktop to VNC.
  restore_keyboard "$display"

  actual="$(current_geometry "$display" || true)"
  if [ "$actual" != "$geometry" ]; then
    printf 'XRDP resize failed (wanted %s, got %s); inspect %s.\n' \
      "$geometry" "${actual:-unknown}" "$resize_log" >&2
    return 1
  fi

  printf 'display=%s resolution=%s\n' "$display" "$actual"
}

show_status() {
  local pid=""
  local display="unknown"
  local actual="unknown"

  pid="$(read_pid || true)"
  if ! pid_matches_bridge "$pid"; then
    pid="$(find_bridge_pid || true)"
  fi
  if [ -r "$display_file" ]; then
    display="$(<"$display_file")"
  fi

  if pid_matches_bridge "$pid" && port_is_listening; then
    actual="$(current_geometry "$display" || true)"
    printf 'running pid=%s display=%s resolution=%s localhost_port=%s\n' \
      "$pid" "$display" "${actual:-unknown}" "$port"
    return 0
  fi

  printf 'stopped localhost_port=%s\n' "$port"
  return 1
}

start_bridge() {
  local pid=""
  local display=""
  local attempt

  pid="$(read_pid || true)"
  if ! pid_matches_bridge "$pid"; then
    pid="$(find_bridge_pid || true)"
  fi

  if pid_matches_bridge "$pid" && port_is_listening; then
    printf '%s\n' "$pid" >"$pid_file"
    display="$(display_from_pid "$pid" || true)"
    if [ -n "$display" ]; then
      printf '%s\n' "$display" >"$display_file"
    fi
    show_status
    return 0
  fi

  if port_is_listening; then
    printf 'Port %s is already used by another process; refusing to replace it.\n' "$port" >&2
    return 1
  fi

  display="${XRDP_VNC_DISPLAY:-$(find_xrdp_display || true)}"
  if [ -z "$display" ]; then
    printf 'No live XRDP Xorg display was found. Connect once with XRDP first.\n' >&2
    return 1
  fi

  if ! DISPLAY="$display" XAUTHORITY="$HOME/.Xauthority" xdpyinfo >/dev/null 2>&1; then
    printf 'Cannot access XRDP display %s with %s.\n' "$display" "$HOME/.Xauthority" >&2
    return 1
  fi

  printf '%s\n' "$display" >"$display_file"

  x11vnc \
    -norc \
    -display "$display" \
    -auth "$HOME/.Xauthority" \
    -localhost \
    -no6 \
    -nopw \
    -forever \
    -shared \
    -repeat \
    -nobell \
    -modtweak \
    -xkb \
    -add_keysyms \
    -rfbport "$port" \
    -bg \
    -o "$log_file" \
    >/dev/null

  for attempt in $(seq 1 30); do
    pid="$(find_bridge_pid || true)"
    if pid_matches_bridge "$pid" && port_is_listening; then
      printf '%s\n' "$pid" >"$pid_file"
      show_status
      return 0
    fi
    sleep 0.1
  done

  printf 'x11vnc did not become ready; inspect %s.\n' "$log_file" >&2
  return 1
}

stop_bridge() {
  local pid=""
  local attempt

  pid="$(read_pid || true)"
  if ! pid_matches_bridge "$pid"; then
    pid="$(find_bridge_pid || true)"
  fi

  if ! pid_matches_bridge "$pid"; then
    rm -f "$pid_file" "$display_file"
    printf 'already stopped\n'
    return 0
  fi

  kill "$pid"
  for attempt in $(seq 1 30); do
    if ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$pid_file" "$display_file"
      printf 'stopped pid=%s\n' "$pid"
      return 0
    fi
    sleep 0.1
  done

  printf 'Process %s did not stop cleanly.\n' "$pid" >&2
  return 1
}

case "$action" in
  start)
    if [ "$auto_resize" != "0" ]; then
      resize_display || printf 'Continuing with the current desktop resolution.\n' >&2
    fi
    # Start or re-adopt x11vnc after resizing. An XRDP reconnect can replace
    # the Xorg process, so doing this last guarantees that VNC follows the
    # final live display.
    start_bridge
    ;;
  stop)
    stop_bridge
    ;;
  restart)
    stop_bridge
    if [ "$auto_resize" != "0" ]; then
      resize_display || printf 'Continuing with the current desktop resolution.\n' >&2
    fi
    start_bridge
    ;;
  resize)
    resize_display
    ;;
  status)
    show_status
    ;;
  *)
    printf 'Usage: %s {start|stop|restart|resize|status}\n' "$0" >&2
    exit 64
    ;;
esac
