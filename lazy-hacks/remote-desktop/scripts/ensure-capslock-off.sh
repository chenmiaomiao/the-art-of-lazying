#!/usr/bin/env bash
set -euo pipefail

# Clear a latched Caps Lock state in X11/XRDP sessions without blindly toggling
# it when it is already off. Then disable Caps Lock as a locking modifier so
# RDP reconnects cannot leave the remote desktop in all-caps mode.
export DISPLAY="${DISPLAY:-:10.0}"
export XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}"

# GNOME may launch the same XDG autostart entry more than once when stale XRDP
# sessions coexist.  Only one watcher may manage a given X display.
display_key="${DISPLAY//[^[:alnum:]_.-]/_}"
lock_root="${XDG_RUNTIME_DIR:-/tmp}"
lock_file="$lock_root/ensure-capslock-off-${UID}-${display_key}.lock"

caps_none_is_active() {
  # Match the complete options line. Splitting on ':' is incorrect here
  # because the option itself contains one ("caps:none").
  setxkbmap -query 2>/dev/null \
    | grep -Eq '^[[:space:]]*options:[[:space:]]*([^,]+,)*caps:none(,|$)'
}

fix_once() {
  local x_state

  if ! command -v xset >/dev/null 2>&1; then
    return 0
  fi

  if ! x_state="$(xset q 2>/dev/null)"; then
    return 0
  fi

  if grep -q 'Caps Lock:[[:space:]]*on' <<<"$x_state"; then
    # Re-enable the normal Caps mapping briefly. If caps:none is already active,
    # a fake Caps_Lock event cannot clear an already-latched Caps indicator.
    setxkbmap -option >/dev/null 2>&1 || true

    python3 - <<'PY'
from Xlib import X, display
from Xlib.ext import xtest

d = display.Display()
keycode = d.keysym_to_keycode(0xffe5)  # XK_Caps_Lock
if keycode:
    xtest.fake_input(d, X.KeyPress, keycode)
    xtest.fake_input(d, X.KeyRelease, keycode)
    d.sync()
PY

    # The temporary reset above removed XKB options. Reapply caps:none once.
    setxkbmap -option caps:none >/dev/null 2>&1 || true
    return 0
  fi

  # Rebuilding the XKB map every two seconds floods GNOME/GTK with settings
  # events. Only change it when caps:none is genuinely absent. This preserves
  # the current layout/model/variant and does not affect normal Shift typing.
  if ! caps_none_is_active; then
    setxkbmap -option caps:none >/dev/null 2>&1 || true
  fi
}

if [ "${1:-}" = "--watch" ]; then
  exec 9>"$lock_file"
  if ! flock -n 9; then
    exit 0
  fi

  while :; do
    fix_once
    sleep 5
  done
else
  fix_once
fi
