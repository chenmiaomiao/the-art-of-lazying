# Multi-hop keyboard input across XRDP, RealVNC, and UU Remote

## Outcome

A shared Ubuntu X11 desktop can accept a Japanese Mac keyboard, a US keyboard,
a phone keyboard, XRDP, RealVNC, and UU Remote without repeatedly replacing
the desktop-wide XKB map. The reliable design keeps physical-key and semantic
text transports separate and fixes modifiers at each nested viewer boundary.

No desktop logout, GNOME restart, XRDP restart, or application restart is
required for the relay correction.

## Why the failure looked like a layout problem

The diagnostic phone sequence showed a precise pattern:

- `(` became `8`
- `)` became `9`
- `$` became `4`
- `&` became `6`
- `"` became `2`
- `?` became `/`
- `!` became `1`
- `{` and `}` became `[` and `]`

Unicode characters such as `€`, `£`, `¥`, and Chinese text could still pass.
That is not random lag and is not evidence that every client should be forced
to US or Japanese layout. The base key arrived, but its Shift state was lost
at an intermediate full-screen VNC Viewer.

The affected cloud-compatible path has two VNC boundaries:

```text
remote RealVNC client
  -> RealVNC Service Mode on console :0
  -> dedicated full-screen RealVNC Viewer
  -> localhost-only x11vnc
  -> existing XRDP/Xorg desktop
```

The middle viewer had `GrabKeyboard=0`. Its base keys reached the target, but
modifiers could be consumed by the intermediate desktop. The fix is
`GrabKeyboard=1` for this dedicated relay window. It is not a recommendation
to grab the keyboard in every ordinary VNC window.

## Layouts and transports are different layers

| Input path | Useful representation | Correct policy |
| --- | --- | --- |
| XRDP physical keyboard | client layout metadata plus scan codes | use the XRDP mapping for that known client |
| VNC | RFB/X11 keysyms | preserve semantic keysyms and reconstruct modifiers |
| UU computer-keyboard panel | physical Windows key events | keep the selected RDP or direct-X11 behavior track |
| UU native phone keyboard | Unicode text commits | keep it separate from physical keys |
| IBus Chinese/Japanese input | application text input | do not replace or disable IBus while fixing XKB |

The workstation's long-lived XRDP display can remain on its known-good JIS
profile while VNC sends semantic keysyms. An isolated test confirmed that the
inner x11vnc boundary delivers 21 shifted symbols and `你好` correctly even
when the target XKB layout is `jp`.

A server cannot perfectly infer US ANSI versus Japanese JIS from an ambiguous
raw key number. If a multi-hop client discards or misreports its keyboard
identity, the missing intent does not exist at the server. Prefer Unicode or
keysym mode for such a hop; keep an explicit per-client JIS fallback for a
genuinely raw physical-key route. Do not install a polling loop that switches
the global XKB map based on the most recent connection.

Semantic phone text needs another distinction. Representable single-line text
can use the fast X11 key route, but newline, tab, CJK, and emoji must remain
text rather than being approximated as key chords. The bridge now selects a
bounded clipboard paste for those commits while leaving Backspace as an
editing key. See
[Preserve multiline dictation and clipboard text](./uu-remote-multiline-dictation-and-clipboard.md).

## Implemented relay settings

Both reusable x11vnc launchers now request the behavior explicitly instead of
depending on version-specific defaults:

```text
-norc -localhost -no6 -nopw -forever -shared
-repeat -nobell -modtweak -xkb -add_keysyms
```

These settings mean:

- `-modtweak`: synthesize the target-layout modifier chord for a keysym;
- `-xkb`: use the complete XKB map;
- `-add_keysyms`: temporarily support a semantic keysym absent from the map;
- `-localhost -no6 -nopw`: keep the unauthenticated listener on IPv4 loopback
  only.

The UU private relay has the persistent setting:

```text
UURB_VNC_GRAB_KEYBOARD=on
```

The RealVNC console relay uses `REALVNC_RELAY_GRAB_KEYBOARD=1` by default. Set
either value to `off`/`0` only if the viewer is no longer a dedicated relay.

For clipboard text, the private UU viewer enables `ClientCutText` but disables
`ServerCutText`; x11vnc is receive-only with `-seldir recv`. The relay selects
X11 `CLIPBOARD` rather than `PRIMARY` and suppresses stale initial transfer.
This lets UU/private clipboard updates enter Ubuntu without allowing semantic
target text to feed back and trigger a duplicate paste. Keyboard grab and
clipboard direction solve different boundaries and should not be conflated.

Reusable source files:

- `lazy-hacks/remote-desktop/scripts/xrdp-vnc-bridge.sh`
- `lazy-hacks/remote-desktop/scripts/realvnc-current-xrdp-desktop.sh`
- the UU bridge's `scripts/test-vnc-keyboard-relay.sh`

## Safe deployment and verification

Install the two workstation helpers, validate them, and restart only the
console relay viewer:

```bash
install -Dm700 \
  lazy-hacks/remote-desktop/scripts/xrdp-vnc-bridge.sh \
  "$HOME/scripts/xrdp-vnc-bridge.sh"
install -Dm700 \
  lazy-hacks/remote-desktop/scripts/realvnc-current-xrdp-desktop.sh \
  "$HOME/scripts/realvnc-current-xrdp-desktop.sh"
bash -n "$HOME/scripts/"{xrdp-vnc-bridge,realvnc-current-xrdp-desktop}.sh
systemctl --user restart realvnc-current-xrdp-desktop.service
```

The last command briefly replaces only the local full-screen Viewer. It does
not stop the XRDP Xorg server or the GNOME session it displays.

Verify the live boundaries without recording typed content:

```bash
systemctl --user status realvnc-current-xrdp-desktop.service
pgrep -af 'vncviewer|x11vnc'
ss -ltnp | grep -E ':592[0-9]'
```

Then use a disposable editor field—not a password field—and separately test:

```text
1234567890
()$&@"?!{}#%*+_|~<>
Ctrl+A  Ctrl+C  Ctrl+V  Enter  Backspace
Chinese/Japanese IME commit
```

The UU repository's isolated test is preferable for repeatable regression
checks because it never touches the live desktop:

```bash
./scripts/test-vnc-keyboard-relay.sh
```

Expected evidence includes `vnc-symbols=23/23 order=exact` and
`isolated VNC keyboard acceptance passed`.
