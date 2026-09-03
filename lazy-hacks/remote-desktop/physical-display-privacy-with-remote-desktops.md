# Physical-display privacy without ending remote desktops

This runbook turns off the physical monitors of an Ubuntu remote-workstation
and an intermediate Windows computer while leaving applications, windows,
remote sessions, and background work running. It provides one command:

```bash
displayprivacy off
displayprivacy on
displayprivacy status
```

The default target is both computers. A single target can also be selected:

```bash
displayprivacy ubuntu off
displayprivacy windows on
displayprivacy status ubuntu
```

`displayprivacy ubuntu off` and `displayprivacy off ubuntu` are equivalent.

## Why this is safer than UU anti-peep under Wine

On the validated Ubuntu bridge, the physical monitor, work desktop, and UU
canvas are different display layers:

```text
physical HDMI monitor       Xorg :0
shared work desktop         XRDP/Xorg :11
UU Windows client in Wine   private Xvfb :20
                             -> localhost VNC -> :11
```

UU's native Windows privacy feature is designed for a Windows or macOS host
whose display stack it controls. The Ubuntu bridge intentionally does not load
UU's Windows display or input drivers. Asking the Wine client to enable native
anti-peep may therefore do nothing or blank the private canvas that UU itself
captures. It cannot reliably target the separate Linux HDMI output.

Linux DPMS is the smaller and reversible boundary: it powers down only the
physical `:0` monitor. XRDP `:11`, UU's private canvas, GNOME, terminal
sessions, and open windows continue unchanged.

## Included helpers

- [`scripts/displayprivacy`](./scripts/displayprivacy) — one front-end for
  both computers
- [`scripts/linux-physical-display-privacy.sh`](./scripts/linux-physical-display-privacy.sh)
  — authenticated X11 DPMS control
- [`scripts/windows-display-privacy.ps1`](./scripts/windows-display-privacy.ps1)
  — Windows display-power request and interactive scheduled-task installer

The Windows command uses an interactive-token scheduled task. This is
important when the request originates over SSH: an ordinary SSH process runs
outside the visible Windows desktop and can report success without reaching
the physical console display.

## Ubuntu installation

Install the front-end and Linux helper together:

```bash
install -Dm0755 scripts/displayprivacy ~/scripts/displayprivacy
install -Dm0755 scripts/linux-physical-display-privacy.sh \
  ~/scripts/linux-physical-display-privacy.sh
```

The helper defaults to display `:0`. It discovers a working Xauthority file
from the current environment, GDM, or `~/.Xauthority`. Override unusual hosts
without editing the script:

```bash
export DISPLAY_PRIVACY_X_DISPLAY=:0
export DISPLAY_PRIVACY_XAUTHORITY=/run/user/1000/gdm/Xauthority
```

## Windows installation

Copy the PowerShell helper to a stable path on the Windows host:

```bash
ssh windows-host 'if not exist "%USERPROFILE%\Scripts" mkdir "%USERPROFILE%\Scripts"'
scp scripts/windows-display-privacy.ps1 \
  windows-host:'Scripts/display-privacy.ps1'
ssh windows-host \
  'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\Scripts\display-privacy.ps1" -Action Install'
```

`Install` creates two on-demand tasks for the currently logged-in user:

- `LazyingArt-DisplayPrivacyOff`
- `LazyingArt-DisplayPrivacyOn`

They have no login, boot, or recurring trigger. They run only when explicitly
requested and do not log out, lock, restart, stop RDP, or close applications.

## Private local configuration

Put host-specific values in an uncommitted user configuration:

```bash
mkdir -p ~/.config/display-privacy
chmod 700 ~/.config/display-privacy
cat >~/.config/display-privacy/config <<'EOF'
DISPLAY_PRIVACY_WINDOWS_HOST='windows-user@windows-host'
DISPLAY_PRIVACY_WINDOWS_SCRIPT='C:\Users\windows-user\Scripts\display-privacy.ps1'
EOF
chmod 600 ~/.config/display-privacy/config
```

The public script contains no passwords, private keys, host addresses, or
account identifiers. SSH must already work with a key.

## Behavior and limitations

- `off` requests software monitor power-off; it does not suspend either PC.
- Keyboard, mouse, or remote input may wake a software-powered-off Windows
  monitor. UU's native anti-peep remains preferable on a native Windows host
  when privacy must survive active remote input.
- Ubuntu remote input aimed at a separate XRDP display normally does not wake
  the physical `:0` display. Local keyboard or mouse input can wake it.
- Windows does not expose a reliable universal power-state query for every
  external monitor. `status` therefore reports the last Windows request and
  clearly labels it as such.
- Do not replace DPMS with `xrandr --output ... --off`: removing an output can
  rearrange windows, change framebuffer geometry, or disturb capture.
- Do not lock or terminate the XRDP work session merely to hide a separate
  physical monitor.

## Direct recovery

Ubuntu:

```bash
DISPLAY=:0 XAUTHORITY=/run/user/$(id -u)/gdm/Xauthority \
  xset dpms force on
```

Windows, from Ubuntu over keyed SSH:

```bash
ssh windows-host \
  'schtasks.exe /Run /TN "LazyingArt-DisplayPrivacyOn"'
```

Physical keyboard or mouse activity should also wake ordinary DPMS-powered
displays.
