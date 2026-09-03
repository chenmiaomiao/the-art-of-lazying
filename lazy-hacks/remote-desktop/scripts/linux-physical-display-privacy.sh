#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: linux-physical-display-privacy.sh off|on|status

Turn only the physical X11 display off or on with DPMS. Applications,
remote desktops, and window geometry remain untouched.

Optional environment variables:
  DISPLAY_PRIVACY_X_DISPLAY      Physical X display (default: :0)
  DISPLAY_PRIVACY_XAUTHORITY     Explicit Xauthority file
EOF
}

action="${1:-status}"
case "$action" in
    off|on|status) ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

physical_display="${DISPLAY_PRIVACY_X_DISPLAY:-:0}"

resolve_xauthority() {
    local candidate
    local -a candidates=()

    if [[ -n "${DISPLAY_PRIVACY_XAUTHORITY:-}" ]]; then
        candidates+=("$DISPLAY_PRIVACY_XAUTHORITY")
    fi
    if [[ -n "${XAUTHORITY:-}" ]]; then
        candidates+=("$XAUTHORITY")
    fi
    candidates+=(
        "/run/user/$(id -u)/gdm/Xauthority"
        "$HOME/.Xauthority"
    )

    for candidate in "${candidates[@]}"; do
        [[ -r "$candidate" ]] || continue
        if DISPLAY="$physical_display" XAUTHORITY="$candidate" \
            xset q >/dev/null 2>&1; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    printf 'Cannot authenticate to physical X display %s.\n' \
        "$physical_display" >&2
    return 1
}

xauthority="$(resolve_xauthority)"
xset_for_display() {
    DISPLAY="$physical_display" XAUTHORITY="$xauthority" xset "$@"
}

show_status() {
    local status
    status="$(xset_for_display q | awk '
        /DPMS \(Display Power Management Signaling\):/ { in_dpms = 1 }
        in_dpms && /DPMS is/ { enabled = $0 }
        in_dpms && /Monitor is/ { monitor = $0 }
        END {
            gsub(/^[[:space:]]+/, "", enabled)
            gsub(/^[[:space:]]+/, "", monitor)
            if (enabled != "") print enabled
            if (monitor != "") print monitor
        }
    ')"
    printf 'Ubuntu physical display %s\n' "$physical_display"
    printf '%s\n' "${status:-DPMS state unavailable}"
}

case "$action" in
    off)
        xset_for_display +dpms
        xset_for_display dpms force off
        printf 'Requested physical monitor power off; desktop remains running.\n'
        ;;
    on)
        xset_for_display +dpms
        xset_for_display dpms force on
        printf 'Requested physical monitor power on.\n'
        ;;
    status)
        show_status
        ;;
esac
