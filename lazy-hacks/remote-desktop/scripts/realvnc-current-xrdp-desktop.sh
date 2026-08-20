#!/usr/bin/env bash
set -euo pipefail

# Present the existing XRDP/Xorg desktop inside the physical console so the
# normal RealVNC Service Mode cloud entry reaches the same live workspace.
# This script never starts, stops, resizes, or logs out XRDP/GNOME.

action="${1:-run}"
unit="realvnc-current-xrdp-desktop.service"
console_display="${REALVNC_RELAY_CONSOLE_DISPLAY:-:0}"
xauthority="${REALVNC_RELAY_XAUTHORITY:-$HOME/.Xauthority}"
bridge_helper="${REALVNC_RELAY_BRIDGE_HELPER:-$HOME/scripts/xrdp-vnc-bridge.sh}"
viewer_target="${REALVNC_RELAY_VIEWER_TARGET:-}"
wait_seconds="${REALVNC_RELAY_WAIT_SECONDS:-5}"

log() {
  printf '%s realvnc-current-desktop: %s\n' \
    "$(date --iso-8601=seconds)" "$*"
}

find_xrdp_display() {
  local line
  local found=""

  while IFS= read -r line; do
    if [[ "$line" =~ Xorg[[:space:]]+(:[0-9]+).*xrdp/xorg\.conf ]]; then
      found="${BASH_REMATCH[1]}"
    fi
  done < <(
    pgrep -u "$(id -u)" -af \
      '/usr/lib/xorg/Xorg :[0-9]+.*xrdp/xorg.conf' 2>/dev/null || true
  )

  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

display_is_ready() {
  local display="$1"
  DISPLAY="$display" XAUTHORITY="$xauthority" \
    xdpyinfo >/dev/null 2>&1
}

find_existing_x11vnc_port() {
  local display="$1"
  local pid
  local cmdline
  local port

  while read -r pid; do
    [ -n "$pid" ] || continue
    [ -r "/proc/$pid/cmdline" ] || continue
    cmdline="$(tr '\0' ' ' <"/proc/$pid/cmdline")"
    [[ " $cmdline " == *" -localhost "* ]] || continue
    [[ " $cmdline " == *" -nopw "* ]] || continue
    if [[ " $cmdline " != *" -display $display "* \
       && " $cmdline " != *" -display ${display}.0 "* ]]; then
      continue
    fi
    port="$(
      ss -H -ltnp 2>/dev/null \
        | awk -v marker="pid=$pid," '
            index($0, marker) && $4 ~ /^127[.]0[.]0[.]1:[0-9]+$/ {
              count = split($4, parts, ":")
              print parts[count]
              exit
            }
          '
    )"
    if [[ "$port" =~ ^[0-9]+$ ]] \
      && [ "$port" -ge 5900 ] \
      && [ "$port" -le 5999 ]; then
      printf '%s\n' "$port"
      return 0
    fi
  done < <(pgrep -u "$(id -u)" -x x11vnc 2>/dev/null || true)

  return 1
}

viewer_pid() {
  local pid
  local cmdline
  local display

  while read -r pid; do
    [ -n "$pid" ] || continue
    [ -r "/proc/$pid/cmdline" ] || continue
    cmdline="$(tr '\0' ' ' <"/proc/$pid/cmdline")"
    [[ "$cmdline" == *"$viewer_target"* ]] || continue
    display="$(
      tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null \
        | awk -F= '$1 == "DISPLAY" { print $2; exit }'
    )"
    [ "$display" = "$console_display" ] || continue
    printf '%s\n' "$pid"
    return 0
  done < <(pgrep -u "$(id -u)" -x vncviewer 2>/dev/null || true)

  return 1
}

force_viewer_fullscreen() {
  local pid="$1"
  local attempt
  local stable=0
  local window=""
  local window_hex=""
  local state=""

  # RealVNC replaces its initial top-level window after connecting. Apply the
  # EWMH fullscreen state to the final visible client and require it to remain
  # present briefly, rather than resizing any remote desktop window.
  for attempt in $(seq 1 80); do
    window="$(
      DISPLAY="$console_display" XAUTHORITY="$xauthority" \
        xdotool search --onlyvisible --pid "$pid" \
          --class 'realvnc-vncviewer' 2>/dev/null \
        | tail -n 1
    )"
    if [ -n "$window" ]; then
      printf -v window_hex '0x%x' "$window"
      DISPLAY="$console_display" XAUTHORITY="$xauthority" \
        wmctrl -ir "$window_hex" -b add,fullscreen
      state="$(
        DISPLAY="$console_display" XAUTHORITY="$xauthority" \
          xprop -id "$window" _NET_WM_STATE 2>/dev/null || true
      )"
      if [[ "$state" == *"_NET_WM_STATE_FULLSCREEN"* ]]; then
        stable=$((stable + 1))
        if [ "$stable" -ge 8 ]; then
          return 0
        fi
      else
        stable=0
      fi
    fi
    sleep 0.25
  done

  return 1
}

run_relay() {
  local target_display=""
  local bridge_status=""
  local existing_pid=""
  local launched_pid=""
  local local_vnc_port=""
  local viewer_status=0

  for command in pgrep seq ss vncviewer wmctrl xdotool xdpyinfo xprop; do
    command -v "$command" >/dev/null 2>&1 || {
      log "missing required command: $command"
      return 1
    }
  done
  [ -x "$bridge_helper" ] || {
    log "missing bridge helper: $bridge_helper"
    return 1
  }

  until display_is_ready "$console_display"; do
    sleep "$wait_seconds"
  done

  while :; do
    target_display="$(find_xrdp_display || true)"
    if [ -n "$target_display" ] && display_is_ready "$target_display"; then
      break
    fi
    sleep "$wait_seconds"
  done

  bridge_status="$(
    XRDP_VNC_AUTO_RESIZE=0 \
    XRDP_VNC_DISPLAY="$target_display" \
      "$bridge_helper" status 2>/dev/null || true
  )"
  if [[ "$bridge_status" == *"display=$target_display "* \
     && "$bridge_status" =~ localhost_port=([0-9]+) ]]; then
    local_vnc_port="${BASH_REMATCH[1]}"
  else
    # UU may already own a localhost-only x11vnc relay for the same X display.
    # Reuse it instead of creating a duplicate stack or racing for port 5922.
    local_vnc_port="$(find_existing_x11vnc_port "$target_display" || true)"
  fi

  if [ -z "$local_vnc_port" ]; then
    # No suitable relay exists. Start the established helper with its optional
    # XRDP resize path disabled so this service cannot alter the shared desktop.
    XRDP_VNC_AUTO_RESIZE=0 \
    XRDP_VNC_DISPLAY="$target_display" \
      "$bridge_helper" start >/dev/null
    bridge_status="$(
      XRDP_VNC_AUTO_RESIZE=0 \
      XRDP_VNC_DISPLAY="$target_display" \
        "$bridge_helper" status
    )"
    if [[ "$bridge_status" == *"display=$target_display "* \
       && "$bridge_status" =~ localhost_port=([0-9]+) ]]; then
      local_vnc_port="${BASH_REMATCH[1]}"
    fi
  fi

  [[ "$local_vnc_port" =~ ^[0-9]+$ ]] \
    && [ "$local_vnc_port" -ge 5900 ] \
    && [ "$local_vnc_port" -le 5999 ] || {
      log "no safe localhost VNC relay found for $target_display"
      return 1
    }
  if [ -z "$viewer_target" ]; then
    viewer_target="127.0.0.1:$((local_vnc_port - 5900))"
  fi

  existing_pid="$(viewer_pid || true)"
  if [ -n "$existing_pid" ]; then
    force_viewer_fullscreen "$existing_pid" \
      || log "warning: existing viewer did not enter fullscreen"
    log "reusing existing console viewer pid=$existing_pid target=$target_display"
    while kill -0 "$existing_pid" 2>/dev/null; do
      sleep 5
    done
    return 0
  fi

  log "opening console $console_display onto existing desktop $target_display via port $local_vnc_port"
  env DISPLAY="$console_display" XAUTHORITY="$xauthority" \
    /usr/bin/vncviewer \
      -AllowMainClose=1 \
      -LogToAddressBook=0 \
      -FullScreen=1 \
      -FullScreenHint=1 \
      -EnableToolbar=0 \
      -AcceptBell=0 \
      -AudioVolume=0 \
      -WarnUnencrypted=0 \
      -VerifyId=0 \
      -Shared=1 \
      -Scaling=Fit \
      -DynamicResolution=0 \
      -GrabKeyboard=0 \
      -SendKeyEvents=1 \
      -SendPointerEvents=1 \
      -MenuKey= \
      -UpdateScreenshot=0 \
      -ShowSplash=0 \
      -EnableAnalytics=0 \
      -ShareFiles=0 \
      -EnableRemotePrinting=0 \
      -ChangeServerDefaultPrinter=0 \
      "$viewer_target" &
  launched_pid=$!

  trap 'kill -TERM "$launched_pid" 2>/dev/null || true' INT TERM
  force_viewer_fullscreen "$launched_pid" \
    || log "warning: viewer connected but did not enter fullscreen"

  set +e
  wait "$launched_pid"
  viewer_status=$?
  set -e
  trap - INT TERM
  return "$viewer_status"
}

case "$action" in
  run)
    run_relay
    ;;
  start|stop|restart)
    systemctl --user "$action" "$unit"
    ;;
  status)
    systemctl --user status "$unit" --no-pager
    ;;
  *)
    printf 'Usage: %s {run|start|stop|restart|status}\n' "$0" >&2
    exit 2
    ;;
esac
