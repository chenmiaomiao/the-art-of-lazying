# Preserve Multiline Dictation and Clipboard Text Through UU Remote

## Result

Direct UU Remote input into an Ubuntu XRDP/Xorg desktop now preserves:

- ordinary fast keyboard text;
- dictated or phone-IME text containing multiple lines;
- Chinese, Japanese, emoji, and other Unicode that has no active keyboard
  chord; and
- one-way UU/private-to-Ubuntu text clipboard transfer without a reverse
  feedback loop.

It also prevents the production regression in which typing one Chinese
dictation commit or smart punctuation pasted unrelated, older clipboard text.
The verified implementation is bridge commit
[`2518016`](https://github.com/lachlanchen/uu-remote-ubuntu-bridge/commit/2518016c2b1fe677584637999d9112df2022744c).

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
  -> separate target-desktop CLIPBOARD and PRIMARY owners
  -> verify that both new X11 selection owners exist
  -> one Shift+Insert paste
```

Backspace remains an editing key. The helper also joins a UTF-16 surrogate
pair when a controller sends its high and low units in separate calls.

The two owners are not redundant. GTK and many graphical editors may read
`CLIPBOARD`, while GNOME Terminal/VTE reads `PRIMARY` for `Shift+Insert`. The
first implementation owned and verified only `CLIPBOARD`; therefore its
content-free broker log could correctly report
`route=x11-clipboard-text ... error=0` while VTE visibly inserted an older
`PRIMARY` selection. That was the real reason a single Chinese commit or smart
quotation appeared to become a paste of unrelated text. It was not a UU
dictation, network, XRDP, locale, or clipboard-history failure.

The helper now starts two independently tracked `xclip` owners, verifies that
both selections changed to new non-empty owners through X11, and emits the
paste chord only after both checks pass. Replacing a semantic commit stops the
two previous scoped owners first. Shutdown also terminates both safely. If
either owner exits, times out, or cannot be verified, the operation fails
closed without issuing `Shift+Insert`.

The text payload is not written to logs or runtime files. It intentionally
remains in both selections after paste; restoring an old selection too quickly
would race applications that request the data asynchronously and would make a
later manual paste inconsistent.

## Production Failure and Root-Cause Proof

The decisive observations were:

1. Ordinary physical typing still worked, so the whole remote desktop was not
   broken.
2. Chinese and smart punctuation selected the semantic route, whose broker
   result count and `error=0` showed that the request reached the helper.
3. The visible text was a previous clipboard item, proving that a paste chord
   occurred but the target application requested a different X11 selection.
4. GNOME Terminal/VTE's `Shift+Insert` behavior explained why owning only
   `CLIPBOARD` could still paste stale `PRIMARY` data.
5. An isolated test seeded `PRIMARY` with a sentinel value before sending
   semantic text. The old implementation reproduced the defect; the two-owner
   implementation replaced the sentinel and delivered the exact requested
   text.

This is a useful diagnostic pattern: a successful injection log proves that
the helper accepted an action, not that the receiving toolkit consumed the
selection the helper expected.

## Clipboard Relay Settings

The dedicated RealVNC Viewer between the private Wine desktop and the shared
Ubuntu desktop now uses explicit settings instead of version-dependent
defaults:

```text
ClientCutText=1
ServerCutText=0
SendPrimary=0
SendInitialClipboard=0
ServerClipboardGraceTime=5000
x11vnc -seldir recv
```

`SendPrimary=0` makes the private VNC clipboard relay source its outgoing text
from that private display's `CLIPBOARD`, not its selection-only `PRIMARY`
buffer. Disabling initial transfer prevents bridge startup from replacing an
existing target clipboard with stale private-display text. The reverse
target-to-private path is disabled at both relay boundaries, preventing
semantic text on Ubuntu from echoing into the UU canvas and triggering another
paste.

This setting does **not** mean the Ubuntu semantic helper should ignore
`PRIMARY`. These are two different boundaries:

- private UU/Wine display -> Ubuntu: relay only intentional `CLIPBOARD`
  changes, one way;
- semantic phone text already on Ubuntu: own both target `CLIPBOARD` and
  `PRIMARY` before synthesizing `Shift+Insert`.

This enables the local UU/Wine-to-Ubuntu text clipboard boundary. Final
controller-side copy/paste still depends on the UU client exposing its own
clipboard synchronization, so validate that separately from phone dictation.
This is text clipboard support, not file transfer.

## Isolated Regression Tests

Run these before changing the live bridge:

```bash
cd ~/ProjectsLFS/uu-remote-ubuntu-bridge

./scripts/test-x11-clipboard-text.sh
./scripts/test-vnc-clipboard-relay.sh
./scripts/test-x11-phone-text.sh
./scripts/test-vnc-keyboard-relay.sh
./scripts/test-x11-mouse.sh
python3 -m unittest discover -s tests
```

The semantic-text test creates its own Xvfb, Wine prefix, editor, and helper.
It first gives `PRIMARY` the sentinel
`stale-primary-must-never-be-pasted`, then proves that exact Chinese, two-line,
and split-surrogate emoji delivery replaces that selection. It therefore
catches both content corruption and the exact stale-selection regression
without typing into the logged-in desktop or reading its clipboard. Failed
runs preserve their isolated artifacts for diagnosis; successful runs clean
them. The test scripts use a shared display-allocation lock so parallel runs
cannot choose the same X socket.

The VNC clipboard test proves that client cut text reaches the isolated relay,
the target Unicode paste is exact, and target clipboard data cannot feed back
to the private display.

Expected semantic evidence is:

```text
clipboard-text=unicode+multiline exact
broker-route=x11-clipboard-text error=0
vnc-clipboard=client-cut-text received server-feedback=disabled
semantic-target-paste=unicode exact clipboard-loop=absent
```

The accepted `2518016` run also retained 98 passing unit tests and unchanged
phone-key, VNC-keyboard, mouse, and one-way clipboard regressions.

## Safe Deployment

The installer preserves existing bridge settings and account state:

```bash
cd ~/ProjectsLFS/uu-remote-ubuntu-bridge
git pull --ff-only origin main
./install.sh --skip-packages --skip-account-login
```

Do not overwrite the running `uu-x11-input` executable in place. Linux may
reject that with `Text file busy`, and a partial manual copy creates an unclear
deployment state. Let the installer stop and replace the bridge-owned helper,
or explicitly stop only `uu-remote-bridge.service`, install through a temporary
file followed by an atomic rename, and start the same service again. Keep a
private rollback copy under
`~/.local/state/uu-remote-bridge/deployment-backups/` before a manual
replacement.

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

For this incident, live verification additionally showed two scoped `xclip`
processes—one owning `CLIPBOARD` and one owning `PRIMARY`—and fresh
`x11-clipboard-text` broker records with positive result counts and
`error=0`. No XRDP, Xorg, GNOME Shell, application, login session, or whole
machine restart was required.

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

For immediate containment of a stale-selection regression, changing only the
saved mode to `keys` and restarting `uu-remote-bridge.service` disables
semantic paste without disturbing the desktop. It may temporarily lose CJK or
multiline semantics, but it cannot paste an unrelated selection. Return to
`auto` after the two-owner helper and its regression test are installed.

## Reusable Lesson

Keyboard keys, IME/dictation commits, mouse events, and clipboard updates are
different protocols even when one remote-control app carries all of them.
When shifted symbols fail, repair the modifier boundary. When multiline or
CJK text fails, preserve semantic text instead of adding key delays or changing
the whole desktop keyboard layout. When the requested semantic route succeeds
but old content appears, inspect the target toolkit's X11 selection semantics;
do not add retries, because retries can paste the wrong selection repeatedly.

Implementation and deeper security details are in:

- [`docs/semantic-text-and-clipboard.md`](../../code/uu-remote-ubuntu-bridge/docs/semantic-text-and-clipboard.md)
- [`docs/security.md`](../../code/uu-remote-ubuntu-bridge/docs/security.md)
- [`docs/debugging-journey.md`](../../code/uu-remote-ubuntu-bridge/docs/debugging-journey.md)
