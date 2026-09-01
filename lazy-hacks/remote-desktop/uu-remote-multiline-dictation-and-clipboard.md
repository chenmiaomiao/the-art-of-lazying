# Preserve Multiline Dictation and Clipboard Text Through UU Remote

## Result

Direct UU Remote input into an Ubuntu XRDP/Xorg desktop now preserves:

- ordinary fast keyboard text;
- dictated or phone-IME text containing multiple lines;
- Chinese, Japanese, emoji, and other Unicode that has no active keyboard
  chord; and
- bidirectional text clipboard transfer through the private VNC relay.

The change restarts only `uu-remote-bridge.service`. It does not restart XRDP,
Xorg, GNOME Shell, or applications on the shared desktop.

## Symptom and Control Experiment

The useful comparison was:

```text
UU -> Windows -> RDP -> Ubuntu: multiline and Chinese dictation worked
UU -> Ubuntu bridge directly:   typing worked, but multiline text collapsed
                                and some non-English commits disappeared
```

This ruled out UU's controller-to-host text transport as the complete cause.
The direct bridge received the text, but represented every UTF-16 unit as a
keyboard event.

Content-free broker metadata confirmed two separate defects:

- line breaks became `VK_RETURN`, so an editor or terminal could interpret
  them as submission rather than text inside one paste;
- `VkKeyScanW` returned `ERROR_NO_UNICODE_TRANSLATION` (`1113`) for characters
  that the active Windows keyboard layout could not express, including CJK.

The old route was therefore suitable for physical keys and representable
characters, but not for semantic text.

## Adaptive Design

The default is now:

```text
UURB_PHONE_TEXT_MODE=auto
```

It separates physical input from semantic input:

```text
ordinary representable phone text
  -> existing authenticated X11 key route

newline / tab / CJK / emoji / other non-representable Unicode
  -> bounded authenticated text request
  -> UTF-16 validation and CRLF normalization
  -> target desktop CLIPBOARD owner
  -> one Shift+Insert paste
```

Backspace remains an editing key. The helper also joins a UTF-16 surrogate
pair when a controller sends its high and low units in separate calls.

The text payload is not written to logs or runtime files. It intentionally
remains in the user's clipboard after paste; restoring an old clipboard too
quickly would race applications that request the pasted data asynchronously.

## Clipboard Relay Settings

The dedicated RealVNC Viewer between the private Wine desktop and the shared
Ubuntu desktop now uses explicit settings instead of version-dependent
defaults:

```text
ClientCutText=1
ServerCutText=1
SendPrimary=0
SendInitialClipboard=0
ServerClipboardGraceTime=5000
```

`SendPrimary=0` selects X11 `CLIPBOARD`, not the selection-only `PRIMARY`
buffer that can contain stale or single-line text. Disabling initial transfer
prevents bridge startup from replacing an existing clipboard with stale text.

This enables the local UU/Wine-to-Ubuntu text clipboard boundary. Final
controller-side copy/paste still depends on the UU client exposing its own
clipboard synchronization, so validate that separately from phone dictation.
This is text clipboard support, not file transfer.

## Isolated Regression Tests

Run these before changing the live bridge:

```bash
cd ~/ProjectsLFS/uu-remote-ubuntu-bridge

./scripts/test-x11-clipboard-text.sh
./scripts/test-x11-phone-text.sh
./scripts/test-vnc-keyboard-relay.sh
./scripts/test-x11-mouse.sh
python3 -m unittest discover -s tests
```

The semantic-text test creates its own Xvfb, Wine prefix, editor, and helper.
It proves exact Chinese, two-line, and split-surrogate emoji delivery without
typing into the logged-in desktop or reading its clipboard. The isolated test
scripts use a shared display-allocation lock so parallel runs cannot choose the
same X socket.

Expected semantic evidence is:

```text
clipboard-text=unicode+multiline exact
broker-route=x11-clipboard-text error=0
```

## Safe Deployment

The installer preserves existing bridge settings and account state:

```bash
cd ~/ProjectsLFS/uu-remote-ubuntu-bridge
git pull --ff-only origin main
./install.sh --skip-packages --skip-account-login
```

UU disconnects briefly. Confirm that the target desktop survived by comparing
its logind leader and Xorg PID before and after, then run:

```bash
./scripts/verify.sh --quick

DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR:-/run/user/$UID}/bus" \
  systemctl --user status uu-remote-bridge.service --no-pager
```

A healthy X11 deployment reports:

```text
PASS  input broker uses the auto phone-text mode
PASS  direct X11 physical-key helper is active
PASS  semantic Unicode and multiline clipboard text is available
```

Then test direct UU in a disposable editor—not a password field—with ordinary
typing, Chinese/Japanese dictation, two lines, copy, and paste. A normal RDP
test does not exercise the direct-UU route.

## Behavior Tracks and Rollback

Keep the adaptive default:

```bash
./install.sh --skip-packages --skip-account-login \
  --phone-text-mode auto
```

Force the former key-only behavior if a host needs rollback:

```bash
./install.sh --skip-packages --skip-account-login \
  --phone-text-mode keys
```

`clipboard` is a diagnostic mode that pastes every phone-text commit except
editing keys. `auto` is preferable because it preserves the low-latency key
route for ordinary text and uses clipboard paste only when text semantics
require it.

## Reusable Lesson

Keyboard keys, IME/dictation commits, mouse events, and clipboard updates are
different protocols even when one remote-control app carries all of them.
When shifted symbols fail, repair the modifier boundary. When multiline or
CJK text fails, preserve semantic text instead of adding key delays or changing
the whole desktop keyboard layout.

Implementation and deeper security details are in:

- [`docs/semantic-text-and-clipboard.md`](../../code/uu-remote-ubuntu-bridge/docs/semantic-text-and-clipboard.md)
- [`docs/security.md`](../../code/uu-remote-ubuntu-bridge/docs/security.md)
- [`docs/debugging-journey.md`](../../code/uu-remote-ubuntu-bridge/docs/debugging-journey.md)
