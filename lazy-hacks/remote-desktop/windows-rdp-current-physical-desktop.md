# Connect to the Current Ubuntu Desktop

## Result

The OptiPlex 7090 UU bridge already owns GNOME Desktop Sharing through one
internal RDP client:

```text
UU Remote
  -> Wine SDL FreeRDP
  -> GNOME Desktop Sharing
  -> current physical GNOME desktop
```

GNOME does not allow a second RDP client to join that same shared desktop
concurrently. The reliable Mac path therefore captures the bridge's existing
`Ubuntu-Desktop-Relay` window and carries only that window through an
authenticated VNC-over-SSH tunnel.

Validated workstation:

| Item | Value |
| --- | --- |
| Ubuntu host | `OptiPlex-7090.local` |
| Address during validation | `192.168.1.100` |
| Ubuntu user | `lachlan` |
| Session | GNOME 46, Wayland, already logged in |
| Internal bridge RDP port | `3391` |
| Mac SSH alias | `glassagent-ubuntu` |
| Mac desktop shortcut | `~/Desktop/Connect to 7090.app` |

Use the hostname or SSH alias instead of relying on the recorded DHCP address.

## Mac Current-Desktop Shortcut

The default **Current Desktop** action uses:

```text
macOS Screen Sharing
  -> localhost:15922
  -> passwordless SSH alias glassagent-ubuntu
  -> Ubuntu 127.0.0.1:5922
  -> x11vnc for Ubuntu-Desktop-Relay only
  -> existing Wine FreeRDP view
  -> current physical GNOME desktop
```

The maintained AppleScript source is:

```text
uu-remote-ubuntu-bridge/scripts/macos-connect-7090.applescript
```

The compiled app on the validated Mac is:

```text
/Users/lachlan/Desktop/Connect to 7090.app
```

It provides four explicit choices:

| Choice | Behavior |
| --- | --- |
| Current Desktop | Opens the existing physical GNOME desktop through VNC over SSH |
| Separate Login (RDP) | Opens GNOME Remote Login on port `3389` |
| Terminal (SSH) | Opens `ssh glassagent-ubuntu` |
| Connection Test | Checks SSH, separate-login RDP, and relay readiness |

The first VNC connection can ask for the bridge credential. Store it in the
Mac login keychain when Screen Sharing offers **Remember password**. The SSH
connection itself is key-only.

## Why the Old Mac Shortcut Was Black

The obsolete shortcut forwarded Mac port `15900` to Ubuntu `[::1]:5900`.
That listener belonged to an unrelated `x11vnc` process on Xvfb display
`:42`, not the physical GNOME desktop. The tunnel worked, but it faithfully
returned a black or stale virtual display.

Do not diagnose that symptom by enabling another VNC server or restarting the
UU bridge. Check the tunnel destination first:

```bash
ssh glassagent-ubuntu \
  '~/.local/bin/uu-remote-console relay-port'
```

The maintained relay reports `5922`. While Screen Sharing is connected,
Ubuntu must show an IPv4 loopback-only listener:

```bash
ss -ltnp | grep '127.0.0.1:5922'
```

The Mac normally has both IPv4 and IPv6 localhost listeners on `15922`.
Screen Sharing may try IPv6 first, while SSH still forwards to Ubuntu's
IPv4-only protected listener.

## Why Direct RDP Does Not Join

The current endpoint meanings are:

| Port | Ownership | Behavior |
| --- | --- | --- |
| `3389` | GNOME system Remote Login | Creates or resumes a separate remote login |
| `3391` | UU bridge, potentially in its application-profile namespace | Internal current-desktop hop already occupied by Wine SDL FreeRDP |
| `5922` | Temporary loopback x11vnc | Exposes only the existing relay window while an SSH-launched viewer is connected |

A direct Mac or Windows RDP connection to `3391` can be rejected or can
compete with the bridge because GNOME Desktop Sharing already has its relay
client. Port `3389` remains useful, but it is deliberately labeled
**Separate Login (RDP)** because it is not the physical desktop.

Older notes and shortcuts that treated LAN port `3391` as a second public
client endpoint describe a previous service arrangement. Do not stop the
working internal relay just to make that historical path available.

## UU Management App Without Recursion

The Ubuntu desktop launcher now runs:

```bash
uu-remote open
```

It opens a normal local TigerVNC window containing only UU's management
window. It does not open the full private Xvfb desktop or the noVNC diagnostic
page, so the physical desktop does not mirror itself recursively.

All Wine processes in the UU prefix must stay on the same private X display.
Wine foreground state is prefix-wide. Moving only `GameViewer.exe` to the
physical display leaves video working but causes the input broker to report:

```text
focus=timeout result=0 error=21
```

On the older local-RDP input path, that state rejects both keyboard and pointer
input. The single-window sidecar keeps the actual UU process on the private
display, forwards only its window to the local desktop, and restores the relay
when the management viewer closes. A host using the native VNC relay plus the
direct-X11 route no longer depends on Wine foreground focus for mouse or
keyboard injection.

## Verification

Run the source-aware bridge verifier on Ubuntu:

```bash
cd ~/Projects/uu-remote-ubuntu-bridge
./scripts/verify.sh --quick
```

The checker supports both the ordinary user unit and the Astrill
application-profile system unit. For the latter it verifies port `3391` in
the GNOME RDP process's network namespace through `/proc/PID/net/tcp*`; the
private listener does not need to appear in the host namespace.

Useful live checks:

```bash
systemctl is-active \
  'io.github.lachlanchen.AstrillLazyRouter.ApplicationProfile@uuremote.service'

pgrep -af 'GameViewerServer.exe|sdl-freerdp.exe'

broker=~/.local/share/wineprefixes/uu-remote/drive_c/users/$USER/Temp/uu-input-broker.log
grep 'focus=' "$broker" | tail -n 20
```

Fresh controller input on the RDP route should report `focus=ready`, a matching
result, and `error=0`. On the direct-X11 route, keyboard records report
`route=x11`, phone text reports `route=x11-text`, and mouse records report
`route=x11-mouse`; all use `focus=bypassed` with matching results and `error=0`.
Historical timeout records can remain earlier in the same log.

## Recovery Rules

Do not restart the bridge merely because a desktop viewer is black. First
close the stale viewer and use **Connection Test** in the Mac app.

If Ubuntu is viewing the Mac in Remmina while the Mac is viewing Ubuntu, the
two windows form a recursive image. Close the Ubuntu-to-Mac Remmina window;
neither endpoint is actually blank.

The relay helper is intentionally bounded:

1. It binds x11vnc only to Ubuntu `127.0.0.1`.
2. It requires VNC authentication in addition to key-only SSH.
3. It waits for a sustained viewer instead of mistaking readiness probes for
   a session.
4. It keeps `Ubuntu-Desktop-Relay` focused while connected.
5. It exits shortly after the final viewer disconnects.

Never commit VNC passwords, SSH private keys, keyring exports, or Mac keychain
data.

## SSH Companion

From the Mac:

```bash
ssh glassagent-ubuntu
```

The alias uses a dedicated private key stored only on the Mac. Ubuntu has the
matching public key in `~/.ssh/authorized_keys`; no password is required.
