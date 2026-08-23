# Control an Ubuntu GNOME Desktop Through UU Remote

## Result

The audited official Windows UU Remote 4.33.0.8907 client runs in a dedicated
Wine prefix and can display and control a logged-in Ubuntu 24.04 GNOME
desktop, including Wayland and XRDP/Xorg targets. This is an experimental,
version-locked compatibility bridge, not a native Linux port.

A guarded 4.34.0.8979 promotion preserved the account and passed warm checks,
but a later cold start exposed an accumulated Wine device-registry stall. The
complete 4.33 prefix was restored without restarting XRDP, and 4.34 acceptance
was withdrawn. The real cause affected both versions and is now repaired
transactionally; see
[Repair UU Remote Stuck at “Finding Routes”](./uu-remote-finding-routes-wine-registry-repair.md).

The backward-compatible `v0.2.0` release fixes the difficult fast-typing case
seen on one XRDP workstation. Physical UU keyboard input can bypass the lossy
nested Wine/FreeRDP conversion and enter the live Xorg desktop through a small
native XTEST helper. In its accepted live run, 256 bounded sampled physical-key
calls used `route=x11`, all returned `error=0`, and typing became very smooth.

The immutable `v0.2.0` tag still behaves exactly as released. A validated
follow-up on `main` now sends layout-representable phone native-keyboard text
through the same helper after converting it to ordinary virtual-key chords.
Video, pointer, and clipboard remain on the established local RDP relay. The
isolated phone-text acceptance preserved all 52 requested transitions, and the
first 72 live calls used `route=x11-text`, returned exact result counts with
`error=0` in 0–2 ms, and produced visibly complete text. The computer-keyboard
panel remained exact as well.

The implementation is kept in the
[public submodule](../../code/uu-remote-ubuntu-bridge). It can be fetched
without a GitHub account:

```bash
git submodule update --init code/uu-remote-ubuntu-bridge
cd code/uu-remote-ubuntu-bridge
./install.sh
```

The installer downloads only pinned upstream artifacts, builds the local
compatibility components, configures a user-level systemd service, and prompts
without echo for a separate GNOME RDP relay password. UU account sign-in is
still required through the official client.

## Data Path

```text
UU controller
  -> GameViewerServer.exe in Wine
       |
       +-> video, mouse, clipboard
       |     -> Windows SDL FreeRDP in private Xvfb
       |     -> GNOME Remote Desktop on 127.0.0.1
       |     -> logged-in GNOME desktop
       |
       +-> physical keyboard and representable phone text
             -> bounded normal-token broker
                  | default: Windows SendInput -> local RDP
                  | opt-in on Xorg: authenticated loopback helper
                  v
             XTEST -> live XRDP/Xorg desktop
```

UU captures the FreeRDP window as a normal Windows application. GNOME Remote
Desktop performs the normal final capture and input integration. The local RDP
hop pins the SHA-256 fingerprint of GNOME's configured TLS certificate. The
direct X11 route changes keyboard delivery only; it does not replace the
working capture or pointer path. The compatible default remains the RDP route,
including on Wayland systems where XTEST cannot target the desktop directly.

## Why the Bridge Is Needed

Windows UU normally uses its signed `gvinput.sys` HID driver. Wine cannot load
that driver, so the audited patch selects UU's existing user-mode `SendInput`
path. Wine then rejects input from UU's service token with error 5, so an
injected IAT hook forwards only bounded `INPUT` records to a normal user Wine
process. That broker focuses the relay window and calls the original Windows
input API.

UU exposes a second keyboard boundary that was easy to misdiagnose. Native
phone IME commits arrive as `KEYEVENTF_UNICODE`, while SDL FreeRDP expects
physical key events. The broker converts representable Unicode characters into
ordinary virtual-key chords and paces new installations by 8 ms per character.
On the compatible RDP route those chords still pass through SDL FreeRDP. On the
opt-in X11 route, the broker validates and maps the complete translated request
before giving it to the helper. The computer-keyboard panel instead sends
physical Windows keys. Characters that Windows cannot represent with the
active keyboard layout are rejected rather than silently corrupted.

On the affected XRDP workstation, adding 8 ms and then 12 ms of physical-key
pacing improved typing but never fully solved it. A bounded 12 ms capture
showed 219 physical-key broker calls with matching results and `error=0`,
while fast letters, Enter, and Ctrl combinations could still disappear. That
proved that a successful Windows API result was not the same thing as delivery
through both nested RDP conversions.

Wine also aborts UU's periodic `EvtOpenPublisherMetadata` call. The injected
DLL returns the normal Windows failure
`ERROR_EVT_PUBLISHER_METADATA_NOT_FOUND`; the caller handles it and continues.
The upstream health monitor is replaced with a sleeping, reversible stub
because it incorrectly killed a healthy Wine process.

## Why Slow Typing and the Mouse Looked Healthy

The old keyboard route was originally chosen because it also works with a
Wayland desktop, where XTEST cannot inject directly:

```text
UU -> normal-token Wine broker -> SendInput -> SDL FreeRDP
   -> GNOME RDP/libei -> XRDP Xorg desktop
```

The broker fixed UU's first proven error: Wine denied `SendInput` from the
service token. A later `SendInput` success meant only that Wine accepted and
queued the requested records. It did not confirm that every subsequent event
loop, focus boundary, keyboard conversion, and nested RDP hop delivered every
transition to the application.

That is why the failure could look inconsistent:

- Slow typing often worked because pauses let the nested queues drain.
- Fast typing exposed the fault because every physical key-down and key-up is
  a discrete edge; neither edge can safely be coalesced or replaced.
- Enter and Ctrl shortcuts were more obvious failures because one omitted
  transition can remove the whole action or invalidate its modifier state.
- Pointer motion still looked smooth because it is state-like. Intermediate
  coordinates can be coalesced while the newest pointer position remains
  useful, and mouse clicks arrive much less frequently than fast keyboard
  edges.
- Adding 8 ms and then 12 ms pacing reduced pressure but retained every
  conversion boundary. All 219 sampled broker calls at 12 ms were accepted
  even while visible omissions remained.

The first direct-X11 route removed only that unreliable local keyboard chain:

```text
UU -> normal-token broker -> authenticated X11 helper
   -> XTEST + XSync -> XRDP Xorg desktop
```

At that milestone it left video, mouse, and clipboard on their working relay.
The later native-VNC mouse failure documented below justified extending the
same authenticated helper without changing video or clipboard. This is why
the evidence supports a careful conclusion: the dominant defect was in the old
local nested route or its resulting back-pressure, but the tests do not
identify one exact proprietary UU, Wine, FreeRDP, GNOME RDP, or libei function
as the sole culprit. They also cannot promise that the controller or network
upstream of the broker will never omit an event.

## Follow-up: Phone Native Keyboard

The physical-key fix did not initially change normal phone-keyboard commits.
A fixed 13-character live A/B test then showed the important boundary: all 13
phone-text calls reached the broker and returned success, but only 11
characters appeared in the target. The phone/controller link and Unicode
normalization were therefore not the missing boundary; the loss occurred after
broker acceptance in the same nested Wine/FreeRDP path.

The follow-up maps the complete normalized chord array first, then submits that
array to the authenticated X11 helper as one keyboard-only request. It falls
back to RDP only if X11 fails before any event is injected, so it never replays
an ambiguously partial shortcut. At this stage the helper accepted only
bounded, non-Unicode keyboard records; Unicode interpretation remained in the
broker. Protocol v2 later added bounded mouse records without moving Unicode
interpretation across that boundary.

An early implementation also exposed a separate 41 ms transport delay between
the broker and helper. It wrote the request header and events separately over
TCP, which interacted badly with small-packet buffering. Coalescing them into
one write and enabling `TCP_NODELAY` reduced the measured helper round trip to
0–2 ms without adding polling, retries, or another daemon.

The isolated Xvfb/Wine acceptance preserved 52/52 requested transitions in
exact order. After installation, the first 72 privacy-safe live phone-text
records all used `route=x11-text`, returned the exact requested count with
`error=0`, and completed in 0–2 ms. Visible phone typing and the UU
computer-keyboard panel were both then confirmed complete. This route covers
text representable by the active Windows keyboard layout; arbitrary CJK or
emoji commits still require a different text protocol if `VkKeyScanW` cannot
map them.

## Root Cause and Final Fix

The useful comparison was not “UU versus the network.” It was the same live
desktop through two paths:

| Path | Result | What it proved |
| --- | --- | --- |
| Direct XRDP keyboard | Normal | Xorg, GNOME, and the target application could consume fast input |
| Direct UU through Wine/FreeRDP | Occasional missing keys | Loss remained inside or before the nested conversion path |
| UU broker metadata at 12 ms | Every sampled call accepted | More `SendInput` success or delay could not prove final delivery |
| Native XTEST burst on isolated Xvfb | 58/58 transitions | The direct helper preserved alphabet, Ctrl, and Enter press/release ordering |
| Live UU with direct X11 route | 256/256 sampled calls successful; typing very smooth | The local conversion defect was practically resolved |
| Phone text on the old nested route | 13/13 broker calls accepted, but 11/13 characters visible | Broker success still did not prove downstream delivery |
| Phone text through isolated X11 route | 52/52 transitions in exact order | Complete normalization and helper submission were lossless |
| Live phone text through X11 | First 72 calls exact, `error=0`, 0–2 ms; visible typing complete | The same narrow bypass resolved the phone native-keyboard loss |
| Mouse through isolated X11 route | 6/6 movement, click, and wheel records; exact final coordinates | The native VNC relay no longer depends on a Wine foreground window |

The final design is deliberately narrow:

1. Keep `rdp` as the global default so a known-good older/Wayland computer
   does not change.
2. Enable `x11` only for an affected, verified Xorg/XRDP desktop.
3. Accept only bounded keyboard and mouse records in the native helper. Phone
   Unicode is normalized and validated in the broker first.
4. Map the complete request before injecting its first event.
5. Fall back to RDP only when failure is known to occur before injection.
6. Never replay an ambiguous partial request; a late original plus a retry can
   type duplicate or dangerous shortcuts.
7. Track held keys and mouse buttons and release them if the broker disconnects.
8. Supervise the helper inside the existing service instead of adding another
   polling daemon.

The helper dynamically loads the existing X11 and XTEST runtime libraries,
binds an ephemeral loopback-only port, and requires a fresh 256-bit token on
each service start. The port file lives in the user's mode-0700 runtime
directory. The token is inherited through process environments rather than
stored in configuration or exposed in the command line. Logs contain counts,
route, timing, and result only—never keycodes, mouse coordinates, or typed text.

## Video Works but Nothing Can Control Ubuntu

First identify the saved relay type:

```bash
grep '^UURB_DESKTOP_RELAY=' ~/.config/uu-remote-bridge/environment
```

With the older `rdp` relay, UU or terminal-agent diagnostics could leave its
management window active instead of `Ubuntu-Desktop-Relay`. Video continued,
but the broker reported `focus=timeout result=0 error=21`. In that architecture
the bounded recovery was:

```bash
uu-agent focus 'Ubuntu-Desktop-Relay'
```

That is not the correct fix for `UURB_DESKTOP_RELAY=vnc`. The full-screen relay
there is a native Linux VNC Viewer window, not a Wine `HWND`. X11 can focus it,
but the old Wine mouse path can never confirm it through
`GetForegroundWindow`, so every click fails at the same timeout. Repeated focus,
network, XRDP, or audio changes do not repair this boundary.

The repository-native fix extends the existing authenticated direct-X11 helper
to mouse input. Protocol v2 carries bounded movement, buttons, and vertical/
horizontal wheel records alongside keyboard input. The helper injects them
into the selected live X11 desktop and the broker reports
`route=x11-mouse focus=bypassed ... error=0`. Hosts still configured with
`UURB_KEYBOARD_ROUTE=rdp` retain the prior route. The mouse fix was introduced
in bridge commit `cc0331b`. The submodule now pins `fa62225`, which preserves
that fix and adds the separately opt-in stable canvas-size follower described
below.

Before deployment, reproduce the input boundaries without touching the live
desktop:

```bash
./scripts/test-x11-phone-text.sh
./scripts/test-x11-mouse.sh
```

The mouse test requires six accepted broker records, exact final coordinates,
and ordered click/vertical-wheel/horizontal-wheel transitions. On the live
host, keep the UU canvas resolution equal to the selected XRDP desktop. A
`1680x1050` XRDP source inside a `1920x1080` private UU canvas produced scaled
side margins and displaced clicks; the reverse mismatch clipped the right or
bottom edge. Aligning both dimensions and restarting only
`uu-remote-bridge.service` fixed the geometry while XRDP, GNOME, and open
applications stayed alive.

Do not run `GameViewer.exe` on the physical display while its server, broker,
and FreeRDP relay remain on the private display. Wine foreground state is
shared across one prefix, even when the X windows are on different displays.
That split was reproduced with both mouse and keyboard records returning
`focus=timeout`, `result=0`, and `error=21` on the older RDP route. Direct X11
input deliberately does not depend on Wine foreground state.

The desktop launcher avoids the split:

```bash
uu-remote open
```

It maps only the existing UU management window through a loopback-only
x11vnc sidecar and opens it in TigerVNC. This looks and behaves like a normal
desktop application without exposing the private root window or launching the
recursive noVNC console. Closing the viewer minimizes UU and restores focus to
`Ubuntu-Desktop-Relay`.

For a Mac that must control the current physical Ubuntu desktop, direct RDP is
also the wrong second connection: the internal Wine FreeRDP client already
occupies GNOME Desktop Sharing. The maintained `Connect to 7090.app` instead
uses key-only SSH plus authenticated, loopback-only VNC to capture the
existing relay window. See
[Connect to the Current Ubuntu Desktop](./windows-rdp-current-physical-desktop.md).

## Installation and Route Selection

The conservative install remains:

```bash
./install.sh
```

For an already authenticated bridge on an affected Xorg/XRDP desktop:

```bash
./install.sh --skip-packages --skip-account-login \
  --keyboard-route x11 --physical-key-delay-ms 0
./scripts/verify.sh --quick
```

The physical delay has two meanings:

- on `rdp`, it sleeps after an accepted physical-key segment;
- on `x11`, it is only a minimum down-to-up hold interval.

Zero is correct for the validated direct route because XTEST plus `XSync`
already preserves ordering without creating upstream back-pressure.

Available route modes are:

| Mode | Behavior |
| --- | --- |
| `rdp` | Compatible default; all input uses the established local relay |
| `x11` | Require direct X11 injection for mouse, physical keys, and representable phone text; verification fails if the helper cannot start |
| `auto` | Select direct input only when the discovered live target is X11 |

The choices are stored in
`~/.config/uu-remote-bridge/environment`. A later plain installer run
preserves them.

### Follow a stable XRDP size without changing XRDP

Windows RDP clients can resize an existing XRDP desktop after UU starts. If UU
deliberately shares that same X11 desktop through the VNC relay, enable the
opt-in follower:

```bash
./install.sh --skip-packages --skip-account-login \
  --follow-desktop-resolution on
```

At startup, the bridge aligns its private canvas to the selected desktop.
While running, it waits through a one-minute grace period, then requires three
identical five-second observations before accepting a new size. It ignores
dimensions below `1024x720`, saves the accepted size atomically, and restarts
only `uu-remote-bridge.service`. It never resizes or restarts XRDP, GNOME,
Xorg, or shared applications. Fixed-size behavior remains the default, so an
upgrade cannot change a working host silently.

Use this only with an X11 target and the VNC relay. It solves framebuffer
geometry; it does not modify mouse calibration or keyboard layout. Disable it
with the same installer option set to `off`.

### Keep keyboard layout an explicit choice

The direct-X11 route follows the selected Ubuntu desktop's XKB layout. It does
not hardcode Japanese JIS. With `layout: jp`, `Shift+6` produces `&` and
`Shift+7` produces `'`; US symbol positions differ. Inspect the target rather
than inferring it from one key:

```bash
DISPLAY=:11 XAUTHORITY="$HOME/.Xauthority" setxkbmap -query
```

RealVNC may feel controller-layout-dependent because it sends interpreted
keysyms. UU's physical route supplies Windows virtual keys/scancodes, which
the helper places on the target XKB key positions. UU does not expose a
trustworthy controller-layout identity, so automatically guessing `jp` or
`us` would destabilize a workstation that alternates among Mac, Windows,
phone, RDP, and VNC. Keep the intended layout explicit; canvas following never
changes it.

For nested VNC, preserve that semantic advantage at both boundaries. The
dedicated viewer must grab modifier keys, and x11vnc should run with explicit
`-modtweak -xkb -add_keysyms` support. This lets US/JIS controllers and phone
text coexist with the selected desktop map without a global layout-switching
loop. The diagnosis and 23/23 symbol/CJK regression test are documented in
[Multi-hop keyboard input across XRDP, RealVNC, and UU Remote](./multi-hop-keyboard-input-across-rdp-realvnc-and-uu.md).

### Select the GNOME desktop independently

On a multi-session workstation, the physical/GDM desktop and a long-lived
XRDP desktop can both have a live GNOME Shell. Pin UU to XRDP by session
identity instead of a temporary `:10` or `:11` number:

```bash
./install.sh --skip-packages --skip-account-login \
  --desktop-target xrdp
```

`auto` preserves historical discovery, `physical` selects the monitor/seat
desktop, and `:N` selects one exact X display. Explicit targets wait rather
than falling back to a different desktop. The selector does not restart XRDP,
GDM, GNOME Shell, Xorg, or applications. See
[Keep UU Remote on the same existing XRDP desktop](./uu-remote-same-xrdp-desktop.md)
for diagnosis, acceptance evidence, rollback, and the distinction between
desktop identity and relay geometry.

### A sound heard during UU may have more than one owner

The nested FreeRDP relay is launched with `/audio-mode:2`; it should not play
the shared desktop back into the host speakers. If a physical speaker pulses
or the remote client receives unwanted sound, inspect `wpctl status` and
`wpctl inspect` before changing UU. In one validated incident, an Unreal `SHI`
process first held a six-channel USB S/PDIF stream. After a later UU restart,
Wine's `GameViewerServer.exe` also opened an output to that physical device
and an active input from the C922 webcam microphone. The latter emitted
continuous PipeWire overrun recoveries. Muting and rerouting only those
identified streams released both physical devices while all desktop and
bridge processes remained alive. A later check found muted regenerated SHI
streams still holding the ALSA PCM in `RUNNING`; exact-device idle suspension
closed it. For hosts that never need UU audio, `UURB_UU_AUDIO=off` disables
Wine PulseAudio only inside UU's dedicated prefix while preserving browser,
Ubuntu, XRDP, and other Wine audio. Because UU still requires a media backend
before a controller can finish connecting, the validated host pairs that
cutoff with a prefix-local ALSA null device; `off` alone can leave the client
waiting at `InitPlayout`. See
[Diagnose speaker pulses during a UU session](./uu-remote-speaker-pulse-pipewire-diagnosis.md).

Rollback does not delete UU login state:

```bash
./install.sh --skip-packages --skip-account-login \
  --keyboard-route rdp --physical-key-delay-ms 0
```

Do not copy `x11` blindly to a Wayland host. The old `v0.1.0` tag remains
immutable, and `v0.2.0` defaults to `rdp`, physical delay `0`, and
unfiltered network adapters.

## Reusable Debugging Lessons

1. **Separate the input modes.** UU's computer-keyboard panel, native phone
   IME, mouse, and clipboard are different protocols. One passing path says
   little about another.
2. **Do not equate API acceptance with visible delivery.** `SendInput`
   returning the requested count proved only that Wine accepted a call, not
   that SDL FreeRDP, GNOME RDP, Xorg, and the application consumed it.
3. **Use a healthy bypass as the control.** Direct XRDP typing on the same
   desktop ruled out CPU load, Xorg, GNOME, and the target application as the
   complete cause.
4. **Instrument boundaries without recording content.** Separate quotas for
   keyboard, phone text, mouse, and other input prevented mouse traffic from
   hiding keyboard evidence while preserving privacy.
5. **Treat pacing as an experiment, not a cure.** Eight and twelve milliseconds
   gave useful evidence and partial improvement. Continuing to increase delay
   would only add back-pressure.
6. **Remove one bad hop, not the whole architecture.** Keep working channels
   unchanged until evidence identifies their boundary. Phone text moved only
   after its own A/B test; mouse moved only after the native VNC relay proved
   the Wine foreground gate could never succeed. Video and clipboard stayed on
   the relay.
7. **Never replay after uncertainty.** Retrying a possibly delivered modifier
   or shortcut is more dangerous than returning one failure.
8. **Preserve known-good machines.** New functionality is opt-in, migration
   retains old behavior, and the immutable release tag remains available.
9. **Verify deployed code, not only source.** The runtime digest prevents a
   freshly pulled checkout from being mistaken for the older installed helper.
10. **Require visible and machine evidence.** The isolated event count, live
    route counters, verifier, and human typing result each prove a different
    boundary; no single one is sufficient alone.

## Reproducible Record

The public submodule contains the complete source and operational record:

- `README.md` plus `i18n/`: polished overview and selector for 11 languages
- `docs/architecture.md`: process and trust boundaries
- `docs/methodology-and-toolkit.md`: complete problem-solving method and tool inventory
- `docs/reverse-engineering.md`: exact `strings`, `xxd`, `objdump`, hashes,
  disassembly addresses, instruction offsets, and replacement bytes
- `docs/upstream-maintenance.md`: repeatable workflow for a new UU release
- `docs/security.md`: credential handling and residual risk
- `docs/troubleshooting.md`: black video, failed input, NLA, and restart checks
- `docs/debugging-journey.md`: evidence from failed hypotheses through the
  direct-X11 physical-key, phone-text, and native-VNC mouse routes
- `docs/xrdp-and-keyboard-recovery.md`: safe XRDP recovery, physical pacing,
  direct-X11 keyboard activation, acceptance, and rollback
- `docs/releases/v0.2.0.md`: backward-compatibility contract and validation
- `docs/mobile-keyboard-parity-handoff.md`: known-good 7090 keyboard baseline,
  cross-host comparison, acceptance matrix, and privacy-safe failure handoff
- `patches/*.json`: approved versioned release identities and patch signatures
- `scripts/stage-uu-release.sh`: private archive/sandbox staging
- `scripts/audit-gameviewer.py`: PE map, semantic candidates, disassembly report,
  draft generation, and explicit finalization gate
- `scripts/patch-gameviewer.py`: generic fail-closed patch, verify, and restore CLI
- `scripts/test-x11-phone-text.sh`: isolated Xvfb/Wine phone-text route and
  exact-order acceptance test
- `scripts/upgrade-uu-remote.sh`: reusable source pull, accepted product
  promotion, bridge refresh, verification, and rollback-safe entry point
- `docs/reusable-upgrade.md`: exact command contract, snapshots, persistent
  user-bus behavior, live failure lessons, and another-computer handoff
- `install.sh`: complete from-scratch setup

No NetEase binary, Wine prefix, account token, device ID, password, private
key, production log, or desktop screenshot is committed.

## Operations

```bash
uu-remote status
uu-remote restart
uu-remote repair-registry
uu-remote logs
uu-remote upgrade status
uu-remote upgrade check
uu-remote upgrade apply
scripts/verify.sh --quick
scripts/verify.sh
```

Use `uu-remote upgrade apply --now` only when a short, deliberate UU
interruption is acceptable. It bypasses the idle delay, not the installer
hash, acceptance, prefix snapshot, account comparison, two runtime checks,
XRDP boundary, or rollback gates. Installed commands live in
`~/.local/bin`; keep that standard directory in `PATH`.

The quick verifier must identify the active route. For this Xorg fix it reports:

```text
PASS  input broker uses a 0 ms physical-key delay
PASS  direct X11 physical-key helper is active
```

After reconnecting the UU controller, fresh content-free physical-key records
use `category=keyboard route=x11`, while normal phone-keyboard records use
`category=text route=x11-text`. Both must show matching requested/result counts
and `error=0`. A test performed through ordinary RDP does not validate the UU
route.

The full verifier holds one GameViewerServer PID for 270 seconds, crossing the
former four-minute failure interval. The original controller acceptance
rendered the live desktop, delivered mouse clicks, and typed through the
broker without disconnecting. The v0.2 direct-keyboard acceptance adds:

- 40 passing source, shell, documentation, migration, and helper-build tests;
- a lossless isolated 58-event alphabet/Ctrl/Enter XTEST run;
- 256 successful sampled live `route=x11` calls with no broker errors;
- the operator's visible report that typing became very smooth and almost all
  former omissions were fixed.

The post-v0.2 phone native-keyboard acceptance adds:

- an isolated 52/52 exact-order X11 text-route test;
- the first 72 live `route=x11-text` calls with exact counts, `error=0`, and
  0–2 ms completion;
- visible confirmation that both phone typing and the UU computer-keyboard
  panel produced complete text.

The wording is intentionally “strong practical acceptance,” not a universal
zero-loss promise. The bounded diagnostics cannot reconstruct typed content,
and UU's controller/network remains outside the host's control.

## Production Upgrade Lessons

The first guarded 4.34 attempts failed closed and left 4.33 usable. They found
three tooling defects rather than a bad accepted UU build:

1. a detached promotion checkout had not built its health-stub verifier;
2. MinGW inserted a PE timestamp/checksum, so equivalent local verifier builds
   did not have identical whole-file hashes; and
3. systemd marked the `Type=simple` bridge active before GNOME RDP had opened
   port 3390, while stale Wine process names let the old readiness loop proceed
   too early.

The reusable updater now builds its verifier inside the pinned checkout, makes
new PE builds reproducible, compares legacy stubs after normalizing only the
documented timestamp/checksum fields, and waits for the actual GNOME listener
plus the selected X11 helper. All code/data differences still fail. A blocked
transaction can be retried only after its pinned tooling commit changes, and
the failed task is retained rather than silently recycled.

The corrected promotion machinery preserved account state, the 8 ms text /
0 ms physical / direct-X11 profile, and XRDP. A later cold-start failure
showed that those checks were still incomplete: 527 failed virtual-input roots
and 21,894 retained Wine Bluetooth devices made UU scan at about 190% CPU
before signaling. Restoring 4.33 reproduced the scan, proving that accumulated
prefix state—not only the new executable—was responsible.

The scoped repair reduced `system.reg` from 34.4 MB to about 3.9 MB;
`update_gvinput` then completed in milliseconds and signaling followed about
four seconds later. Current verification requires those milestones from the
current service start. Version 4.34 remains statically reviewed but has no
promotion acceptance until it passes the new stopped-prefix test. Full
evidence and recovery commands are in
[the finding-routes incident guide](./uu-remote-finding-routes-wine-registry-repair.md)
and the reusable transaction is documented in
[`docs/reusable-upgrade.md`](../../code/uu-remote-ubuntu-bridge/docs/reusable-upgrade.md).

## Upstream Updates

Unknown UU binaries remain blocked. A new version follows this workflow:

1. Stage the installer without touching the live prefix; use the explicit
   root-managed, networkless systemd sandbox only if archive extraction fails.
2. Generate PE sections, semantic landmarks, masked candidates, targeted
   disassembly, hashes, and a deliberately non-runnable draft manifest.
3. Re-establish every patch's semantics against a Windows reference and the
   complete new function control flow.
4. Finalize only reviewed candidates; the tool derives the full patched hash
   without modifying the binary.
5. Prove patch, expected-state verify, byte-identical restore, controller
   input, reconnect, restart, and 270-second stability on disposable state.

The installer accepts an approved future manifest with
`--release-manifest`. Drafts, ambiguous signatures, unknown hashes, overlapping
patches, and restore over a different release fail closed.

## Automatic Checks and Repair Resume

Describe the validated input behavior instead of calling the two machines
"v1" and "v2":

| Behavior tag | Host profile |
| --- | --- |
| `track-rdp-broker-20260724` | Keep the compatible broker and nested RDP keyboard route on a computer where it is already smooth |
| `track-direct-x11-20260724` | Keep direct physical-key and normalized phone-text injection on a validated X11/XRDP computer |

Both immutable tags use the union source; the saved route and timing settings
select the behavior. The daily checker never switches profiles. Enable it only
after the normal phone and computer-keyboard acceptance passes:

```bash
cd code/uu-remote-ubuntu-bridge
git fetch --tags origin
./scripts/configure-updater.sh enable --track TRACK_NAME \
  --model codex-auto-review --reasoning-effort medium \
  --no-auto-reinstall --no-auto-promote
uu-remote update
```

`uu-remote-update-check.timer` runs a metadata check daily and after reboot. A
same-version build is downloaded once for a complete SHA-256; an unchanged
ETag, size, and cached hash make later checks metadata-only. A healthy UU relay
is never restarted by this check.

`uu-remote-repair-monitor.timer` performs a read-only health check every 15
minutes. The default profile records and analyzes a persistent fault without
restarting the live bridge; live restart/reinstall requires a separate
explicit opt-in. For an unknown upstream build or a persistent runtime fault, it
creates a private repair clone and starts Codex with explicit
`codex-auto-review`/`medium` settings. The Codex thread UUID, context, events, and test
result are saved atomically, so the same task resumes after reboot or network
interruption with bounded backoff.

Codex cannot approve its own binary manifest, push the repair clone, use sudo,
or deploy an unknown installer. Static candidates still require the semantic
review and Windows/controller acceptance above. Full setup, state, privacy,
failure, and another-computer instructions are in
[`docs/automatic-updates.md`](../../code/uu-remote-ubuntu-bridge/docs/automatic-updates.md)
and
[`docs/release-tracks.md`](../../code/uu-remote-ubuntu-bridge/docs/release-tracks.md).

`--auto-promote-accepted` remains an explicit operator option, but it should
be enabled only after the exact release has passed the stopped-prefix startup,
fresh-signaling, controller-input, login-preservation, and stability gates.
The production workstation currently leaves both automatic reinstall and
automatic promotion disabled.

Restore the audited upstream files while keeping UU account state:

```bash
./uninstall.sh --dry-run
./uninstall.sh
```

The dry run validates both audited backups without stopping anything. Use
`./uninstall.sh --purge` only when the dedicated Wine prefix, bridge
credential, and UU account state should also be deleted.

## Security Boundary

This setup preserves both UU and GNOME authentication. It does not modify an
OS account database, bypass a login, install a kernel driver, or expose a new
remote-control protocol. The service and bridge run as the logged-in Unix
user. Treat the Wine prefix and runtime logs as private because they contain
UU account and device metadata.

Do not weaken the patcher's version and signature checks after a UU update.
Audit the new executable and update the pinned hashes and disassembly record
as one reviewed change.
