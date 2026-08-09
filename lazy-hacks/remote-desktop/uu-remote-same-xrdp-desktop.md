# Keep UU Remote on the Same Existing XRDP Desktop

## Problem

A Linux workstation can have more than one live GNOME desktop for the same
user. For example:

- GDM automatic login owns the physical `:0` desktop;
- Windows RDP/XRDP owns a long-lived `:10` or `:11` desktop;
- the UU Remote Ubuntu bridge owns a private Xvfb canvas such as `:20`.

If bridge auto-discovery follows the systemd user manager's physical
`DISPLAY=:0`, direct UU shows a clean desktop even though all useful windows
remain open in XRDP. This is a target-selection error, not a logout or loss of
applications.

## Safe Diagnosis

Inspect session identity before restarting anything:

```bash
loginctl list-sessions

for pid in $(pgrep -u "$UID" -x gnome-shell | sort -n); do
  printf 'gnome-shell pid=%s ' "$pid"
  tr '\0' '\n' <"/proc/$pid/environ" |
    sed -n -e 's/^DISPLAY=/display=/p' \
           -e 's/^DBUS_SESSION_BUS_ADDRESS=/bus=/p' |
    paste -sd ' ' -
  sed -n 's#.*session-\([^/]*\)\.scope.*#session=\1#p' \
    "/proc/$pid/cgroup" | head -n 1
done

journalctl --user -u uu-remote-bridge.service -n 30 --no-pager
```

The old failure is recognizable from a journal line such as:

```text
GNOME Desktop Sharing is relaying x11 :0.
```

when the active `xrdp-sesman` session is on another display.

Do not restart `xrdp-sesman`, GDM, GNOME Shell, or Xorg merely to repair this
selection. Those actions can destroy the existing desktop that should be
preserved.

## Persistent Target Selection

Bridge commit `4760ccd` adds `UURB_DESKTOP_TARGET` independently of
`UURB_DISPLAY`:

| Value | Selection rule |
| --- | --- |
| `auto` | Historical manager-display discovery and fallback |
| `xrdp` | Active GNOME Shell whose logind service is `xrdp-sesman` |
| `physical` | Seat-attached or GDM/persistent-manager GNOME desktop |
| `:N` | One exact X display, with optional `.0` suffix |

`UURB_DISPLAY` still controls only the private Xvfb canvas used by Wine.
Desktop target and private canvas are intentionally separate settings.

Explicit targets fail closed. If the requested session is unavailable, the
user service waits instead of silently sharing another desktop. This also
makes `xrdp` more durable than hard-coding `:11`, because XRDP can receive a
different display number after logout or reboot.

## Configure an XRDP Workstation

```bash
cd ~/ProjectsLFS/uu-remote-ubuntu-bridge
git pull --ff-only origin main

./install.sh --skip-packages --skip-account-login \
  --desktop-target xrdp
```

The installer validates and preserves the choice in:

```text
~/.config/uu-remote-bridge/environment
```

The relevant entry is:

```text
UURB_DESKTOP_TARGET=xrdp
```

A plain later installer run retains it.

## Non-Disruptive Live Recovery

After the tested launcher and environment setting are in place, restart only
the bridge user service:

```bash
DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR:-/run/user/$UID}/bus" \
  systemctl --user restart uu-remote-bridge.service
```

UU briefly disconnects. XRDP, GDM, both GNOME sessions, Xorg, and open
applications must remain running.

Healthy journal output identifies the target by both service and current
display:

```text
Desktop target 'xrdp' selected xrdp-sesman session ... on :11.0.
GNOME Desktop Sharing is relaying x11 :11.0.
Physical keyboard input uses direct X11 injection on :11.0 ...
```

The session ID and display are examples; `xrdp-sesman` is the durable
identity.

## Verification

```bash
cd ~/ProjectsLFS/uu-remote-ubuntu-bridge
python3 -m unittest discover -s tests -v
bash -n install.sh scripts/verify.sh scripts/uu-remote-bridge

systemctl is-active xrdp xrdp-sesman
pgrep -a -u "$UID" -x gnome-shell

DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR:-/run/user/$UID}/bus" \
  systemctl --user show uu-remote-bridge.service \
    -p ActiveState -p SubState -p MainPID -p NRestarts
```

On the validated workstation, all 94 repository tests passed; XRDP/Xorg and
both GNOME Shell PIDs were unchanged; and all 83 visible XRDP windows survived
the bridge-only restart.

## Geometry Is a Separate Decision

The shared XRDP framebuffer and private UU canvas can have different sizes.
That may produce clipping or unused margins, but it does not explain a wholly
different desktop. First fix desktop identity. Align resolution later as a
separate reversible operation so an active XRDP layout is not unexpectedly
resized.

## Rollback or Physical-Desktop Mode

Restore historical discovery:

```bash
./install.sh --skip-packages --skip-account-login \
  --desktop-target auto
```

Deliberately follow the physical/GDM desktop:

```bash
./install.sh --skip-packages --skip-account-login \
  --desktop-target physical
```

The selector changes only which existing GNOME Shell the local relay mirrors;
it does not create, terminate, or migrate GNOME sessions.

## Related Material

- [UU Remote Ubuntu bridge](./uu-remote-ubuntu-bridge.md)
- [Safely upgrade the bridge](./uu-remote-safe-upgrade-runbook.md)
- [XRDP client stall and UU keyboard recovery](../../code/uu-remote-ubuntu-bridge/docs/xrdp-and-keyboard-recovery.md)
- [Bridge troubleshooting](../../code/uu-remote-ubuntu-bridge/docs/troubleshooting.md)
