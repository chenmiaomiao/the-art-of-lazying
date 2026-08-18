# Remote Desktop Hacks

Practical notes for keeping Ubuntu remote access usable when GNOME native RDP, RealVNC, and app launches interact badly.

## Files

- [OptiPlex 3040 macOS post-install and Sequoia staging](../hackintosh/optiplex-3040-macos-postinstall-and-sequoia-staging.md)
  - install signed native UU Remote and configure its required macOS consent
  - establish separate key-only SSH identities for macOS and Windows on the same hardware
  - enable LAN-only Apple Remote Management and persistent never-sleep behavior
  - stage, verify, and explicitly defer the Sequoia upgrade

- [windows-rdp-bootstrap-to-ssh-and-uu-remote.md](./windows-rdp-bootstrap-to-ssh-and-uu-remote.md)
  - how Remmina RDP was used as the one-time Windows bootstrap path
  - how to install OpenSSH Server, add an administrator public key, and keep TCP 22 LAN-scoped
  - companion helper: [scripts/enable-windows-openssh.ps1](./scripts/enable-windows-openssh.ps1)
  - the verified Ubuntu SSH alias and Windows service/firewall/ACL checks
  - how to install and verify native NetEase UU Remote on Windows
  - how to launch the UU GUI in the active RDP session when the command originates over SSH

- [uu-remote-ubuntu-bridge.md](./uu-remote-ubuntu-bridge.md)
  - how the official Windows UU client in Wine displays and controls the live Ubuntu GNOME desktop
  - the Xvfb, SDL FreeRDP, GNOME RDP, and bounded input-broker data path
  - why accepted `SendInput` calls could still lose fast letters, Enter, and Ctrl through the nested RDP hop
  - why deliberate slow typing and apparently smooth mouse motion masked the keyboard-only loss
  - how the opt-in authenticated X11/XTEST helper made direct-UU typing very smooth on XRDP
  - the lossless 58-event isolated test and 256-call content-free live acceptance record
  - why normal phone-keyboard text remained lossy after the physical-key fix
  - the 52/52 isolated phone-text test and first 72 exact live `x11-text` calls
  - confirmation that both phone typing and the UU computer-keyboard panel are complete
  - why a native VNC relay made the old Wine mouse focus gate fail, and the
    authenticated direct-X11 mouse fix with exact click/wheel acceptance
  - why a mismatched XRDP/UU framebuffer caused white margins, clipped edges,
    and displaced clicks, plus opt-in debounced canvas-size following
  - why `Shift+6` producing `&` is normal on JIS and why controller layout is
    not guessed automatically across Mac, Windows, phone, RDP, and VNC
  - where to find the public source submodule and exact `xxd`/`objdump` patch record
  - the one-command installer, verification, rollback, and security boundaries
  - the versioned manifest, sandboxed staging, and audited upstream-update workflow
  - descriptive RDP-broker and direct-X11 behavior tags for cross-machine handoff
  - reboot-persistent daily checks and resumable Codex repair without restarting a healthy relay
  - the reusable guarded 4.33-to-4.34 upgrade, preserved login/input profile,
    XRDP-independent transaction, and complete-prefix rollback

- [uu-remote-same-xrdp-desktop.md](./uu-remote-same-xrdp-desktop.md)
  - why UU can show a clean physical desktop while all windows remain alive in XRDP
  - how persistent `xrdp` targeting follows the session by logind identity instead of a temporary display number
  - how to restart only the UU bridge and prove that XRDP, GNOME Shell, Xorg, and open windows were preserved
  - `auto`, `physical`, and exact-display rollback or diagnostic modes

- [uu-remote-speaker-pulse-pipewire-diagnosis.md](./uu-remote-speaker-pulse-pipewire-diagnosis.md)
  - how to prove whether unwanted sound belongs to UU, another app, or both at different times
  - identify a PipeWire stream by process, media class, target sink, and live process command
  - isolate UU playback and capture from physical speakers and microphones without restarting the desktop
  - distinguish a muted stream from a genuinely closed ALSA PCM and disable UU-only Wine audio when unwanted
  - use Unreal `-nosound` for deterministic remote previews while retaining an explicit audio override

- [uu-remote-safe-upgrade-runbook.md](./uu-remote-safe-upgrade-runbook.md)
  - distinguish a public bridge-source refresh from proprietary UU promotion
  - preserve login, keyboard route, XRDP, and complete-prefix rollback
  - explain why the warm 4.34 promotion succeeded but its later cold-start
    acceptance was withdrawn
  - use the current read-only check, accepted apply, post-upgrade controller
    test, and conservative automatic-maintenance commands

- [uu-remote-finding-routes-wine-registry-repair.md](./uu-remote-finding-routes-wine-registry-repair.md)
  - why “finding routes” was a local pre-signaling device scan rather than a
    DNS, Ethernet, firewall, or XRDP failure
  - evidence from 527 stale virtual-input roots and 21,894 retained Wine
    Bluetooth devices
  - the idempotent `uu-remote repair-registry` transaction, private rollback,
    exact cold-start verification, and fail-closed release-acceptance rule

- [uu-remote-agent-and-headless-mac.md](./uu-remote-agent-and-headless-mac.md)
  - use the official UU controller CLI without hard-coded Wine or display paths
  - open bounded macOS terminal-agent sessions for Xcode and simulator checks
  - distinguish device heartbeat, terminal, framebuffer, and input health
  - diagnose the 7050 iMac's headless zero-frame failure and bootstrap a
    persistent virtual screen plus keyed SSH from one temporary display

- [native-gnome-rdp-vs-xrdp-on-ubuntu-24-04.md](./native-gnome-rdp-vs-xrdp-on-ubuntu-24-04.md)
  - why GNOME native RDP could crash the remote desktop session on app launch
  - why `xrdp` was chosen as the safer default
  - the exact `xrdp` setup used on this workstation
  - why `xrdp` is safer but laggier than native GNOME RDP here
  - how the `Xvnc` backend was fixed by moving XRDP to TigerVNC
  - why stale old `Xorg` and new `Xvnc` sessions can fight over single-instance apps
  - why Firefox feels different now after moving from the Ubuntu snap to Mozilla's `deb` package

- [gnome-system-rdp-remote-login-on-ubuntu-24-04.md](./gnome-system-rdp-remote-login-on-ubuntu-24-04.md)
  - why GNOME user desktop sharing can fail when no desktop session is active or the keyring is locked
  - how to configure GNOME's system Remote Login RDP backend with `grdctl --system`
  - how to verify the `3389` listener before connecting from Windows App / Microsoft Remote Desktop

- [gnome-rdp-existing-desktop-with-autologin-on-ubuntu-24-04.md](./gnome-rdp-existing-desktop-with-autologin-on-ubuntu-24-04.md)
  - why system Remote Login on `3389` cannot attach to an already-running automatic-login session
  - how native Desktop Sharing on `3390` displays and controls the existing GNOME desktop
  - how to survive the locked login keyring with a session collection and `systemd-creds`
  - the reusable installer, credential loader, hardened systemd template, and rollback path
  - dedicated SSH keys, mDNS, SAN certificates, Remmina, GFX, and end-to-end verification

- [windows-rdp-current-physical-desktop.md](./windows-rdp-current-physical-desktop.md)
  - why the UU bridge's internal RDP client prevents a second client from joining the current desktop
  - the verified Mac `Connect to 7090.app` path through authenticated VNC over key-only SSH
  - why the obsolete `[::1]:5900` tunnel reached a black Xvfb desktop
  - how the app-only UU launcher avoids recursive mirroring without splitting one Wine prefix across displays
  - service ownership, namespace-aware verification, recovery rules, and the SSH alias

- [xrdp-cjk-input-on-ubuntu-24-04.md](./xrdp-cjk-input-on-ubuntu-24-04.md)
  - why Chinese and Japanese input can work in terminal/Sublime but fail in Chrome, Firefox, and Typora over `xrdp`
  - how to use `ibus-mozc`, `libpinyin`, and `Wubi` together
  - how to make `ibus-daemon` come up reliably in XRDP sessions with `~/.xsessionrc`

- [japanese-mac-keyboard-through-windows-xrdp-on-ubuntu-24-04.md](./japanese-mac-keyboard-through-windows-xrdp-on-ubuntu-24-04.md)
  - how to keep Windows usable for Japanese input first
  - how to make Ubuntu XRDP use layout `jp` with `applealu_jis` and variant `mac` kept as separate settings
  - why putting the literal value `jp(mac)` in XRDP's layout map moved Kana onto the primary letter/number layer
  - why TigerVNC `RawKeyboard=1` was tested but did not repair the macOS RDP modifier path
  - how direct XRDP Xorg plus Windows App Unicode mode restored printable symbols in the double-remote Mac route
  - how physical JIS geometry, Unicode/Scancode transport, and Japanese IME/Kana input differ
  - why a corrected XRDP `jp` map can still type US-like characters when Unicode mode forwards the Mac relay's `ABC` source
  - a native Swift helper for listing and selecting macOS ABC, Romaji, and Kana input sources
  - why the Mac and Windows client routes require separate XRDP compatibility mappings
  - how valid saved credentials preserve the old one-password direct-login workflow
  - why this should be an XRDP-only override instead of a whole-machine keyboard change

- [click-to-open-private-vnc-for-an-xrdp-desktop.md](./click-to-open-private-vnc-for-an-xrdp-desktop.md)
  - why Windows App Unicode mode fixed printable symbols but lost `Ctrl`, while Scancode still lost held `Shift`
  - how to attach localhost-only `x11vnc` to the existing XRDP/Xorg desktop
  - how a Mac launcher creates an SSH tunnel and opens RealVNC Viewer with one click
  - how the helper enforces a true `1620x1080` framebuffer and restores the Japanese Mac XKB map
  - why the resize credential belongs in GNOME Keyring instead of a script
  - how to start, stop, verify, and recover the bridge without rebooting or exposing a VNC port

- [xrdp-caps-lock-all-uppercase-fix-on-ubuntu-24-04.md](./xrdp-caps-lock-all-uppercase-fix-on-ubuntu-24-04.md)
  - why Ubuntu can show Caps Lock off while XRDP still types uppercase
  - how to diagnose Caps Lock, Shift, and XRDP keymap state separately
  - how to patch XRDP keymaps so client-side Caps Lock is ignored while normal `Shift` still works

## Scope

- Ubuntu 24.04
- GNOME 46
- Windows App / Microsoft Remote Desktop
- Remmina RDP as a Windows bootstrap client
- Windows OpenSSH and NetEase UU Remote recovery access
- RealVNC, native GNOME RDP, and XRDP comparison
- GNOME Desktop Sharing for an existing automatic-login session
