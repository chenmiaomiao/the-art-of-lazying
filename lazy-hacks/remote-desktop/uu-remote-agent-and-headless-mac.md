# Use the UU Remote Agent for Mac and iOS Work

## Result

The Ubuntu UU bridge exposes the official controller's command-line and remote
terminal surfaces through:

```bash
~/.local/bin/uu-agent
```

The maintained source is
[`code/uu-remote-ubuntu-bridge/scripts/uu-agent`](../../code/uu-remote-ubuntu-bridge/scripts/uu-agent).
It discovers the active Xvfb display, Xauthority file, Wine prefix, and
`uuyc-cli.exe` from the running systemd service. Scripts do not need a fixed
display number, Wine path, or UU device ID.

This was verified with UU Remote 4.34.0.8979. The vendor CLI is useful but is
not documented as a stable public API, so re-run its help after every upstream
update.

## Commands

```bash
uu-agent version
uu-agent list
uu-agent status
uu-agent runtime
uu-agent windows
uu-agent snapshot
```

`list` can expose private device names and IDs. `snapshot` can expose the
complete controller or remote screen. Do not paste either output into a public
issue or commit it. Captures default to a mode-`0600` directory under
`~/.local/state/uu-remote-agent/`.

Open a Mac terminal agent:

```bash
uu-agent term 'Mac device name' --shell zsh --new-session
```

Run bounded non-interactive discovery:

```bash
printf '%s\n' \
  'sw_vers' \
  'xcodebuild -version' \
  'xcrun simctl list devices available' \
  '/usr/sbin/system_profiler SPDisplaysDataType' \
  'exit' |
  uu-agent term 'Mac device name' --shell zsh --new-session
```

Select the exact current device name from `uu-agent list`. Never put the
returned device ID in source code or documentation.

## GlassAgent Workflow

GlassAgent includes a narrower operator wrapper:

```bash
cd ~/Projects/GlassAgent
./scripts/uu_mac_agent.sh preflight 'Mac device name'
./scripts/uu_mac_agent.sh ios-status \
  'Mac device name' /Users/USER/Projects/GlassAgent
```

After choosing one available simulator and confirming a clean root checkout:

```bash
./scripts/uu_mac_agent.sh ios-validate \
  'Mac device name' \
  /Users/USER/Projects/GlassAgent \
  SIMULATOR_UDID
```

This delegates to GlassAgent's existing guarded iOS validator. It does not
weaken the explicit simulator, clean-tree, output, bundle, or cleanup checks.

Use the terminal for Git, builds, logs, `xcodebuild`, and `simctl`. Use the GUI
only when Xcode, Simulator, System Settings, or a permission prompt must be
seen. Do not automate signing-password entry, agreements, purchases, firmware,
storage changes, or a final App Store/TestFlight submission.

## Online Is Not Interactive

Check these UU boundaries separately:

1. the account says the device is online;
2. the remote terminal opens;
3. a framebuffer renders;
4. pointer and keyboard input are accepted.

One success does not prove the next. A Mac can remain online while its terminal
agent times out or its GUI connection remains blank.

## Headless 7050 iMac

The 7050 iMac remained online after its monitor was unplugged, but:

- its UU terminal timed out waiting for the remote open response;
- GUI attempts did not become usable;
- LAN SSH and macOS Screen Sharing were not listening.

The missing active display is the leading explanation, but it has not been
proven as the only cause. Because every interactive path is currently closed,
the host cannot safely install its own recovery path remotely.

Use a monitor or an HDMI/DisplayPort dummy plug once, then configure:

1. UU Screen Recording and Accessibility permissions.
2. Remote Login with a dedicated public key.
3. macOS Screen Sharing for one named user.
4. A persistent virtual screen for software-only headless use.

BetterDisplay officially supports virtual screens for headless Macs. On macOS
13.2 or later:

```bash
brew install --cask betterdisplay
open -a BetterDisplay
/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay help
```

Create one `1920x1080` virtual screen named `UU-Headless`, enable BetterDisplay
at login, reboot with the monitor still attached, and verify:

```bash
/usr/sbin/system_profiler SPDisplaysDataType
```

Then unplug the monitor and test UU video, input, terminal, SSH, and Screen
Sharing independently. BetterDisplay's current CLI supports
`create -type=VirtualScreen`, `virtualScreenName`, `resolutionList`,
`virtualScreenHiDPI`, and `connected`. Query the installed version's help
before scripting them. Never run its unqualified `discard` operation.

A display-emulator plug remains the lowest-maintenance fallback because it
does not depend on a login item, app startup, or virtual-screen state.

## Troubleshooting Matrix

| Observation | Meaning | Next step |
| --- | --- | --- |
| Device offline | UU host heartbeat absent | Check power, LAN, login, and UU startup |
| Online, terminal timeout | UU service reachable, agent did not open | Restore display or independent SSH/Screen Sharing |
| Terminal works, GUI blank | Shell path healthy, framebuffer unhealthy | Inspect displays and virtual-screen state |
| GUI renders, no input | Capture healthy, control permission/path unhealthy | Recheck Accessibility and UU input |
| CLI exits `2` | Ubuntu controller IPC unavailable | Check `uu-remote-bridge.service` |
| CLI exits `5` | Vendor operation timed out | Inspect state before retrying |

## Sources

- [Bridge controller-agent implementation](../../code/uu-remote-ubuntu-bridge/docs/controller-agent.md)
- [BetterDisplay CLI documentation](https://github.com/waydabber/BetterDisplay/wiki/Integration-features%2C-CLI)
- [BetterDisplay headless virtual screens](https://betterdisplay.dev/)
- [Apple Screen Sharing guide](https://support.apple.com/guide/mac-help/mh11848/mac)
