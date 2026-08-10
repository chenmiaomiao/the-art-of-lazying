# Keep Intel CoreSimulator GPU Hangs Out Of Release Work

## Symptom

An Intel Hackintosh can appear frozen while iOS Simulator says it is loading.
In the verified 2026-08-10 incident, the machine still had ample memory and
disk space. Kernel diagnostics instead recorded repeated `GPU Reset` events
from CoreSimulator's `SimMetalHost`, with an `Intel GPU Hang Summary`.

Treat this as a graphics-path failure when all of these are true:

- the desktop or remote display stops updating during simulator startup;
- a recent `*.gpuRestart` report names `SimMetalHost` or `SimRenderServer`;
- WindowServer reports display loss or reconfiguration errors;
- memory pressure, swap, and disk capacity remain healthy.

Do not erase simulators, reinstall Xcode, clear every cache, or modify OpenCore
until the evidence distinguishes those causes.

## Safe Headless Mode

After rebooting into the known-good macOS volume, keep every virtual device
shut down and disable framebuffer compositing for the current user:

```bash
xcrun simctl shutdown all
defaults write com.apple.CoreSimulator \
  FramebufferServerRendererPolicy -string none
defaults write com.apple.iphonesimulator \
  NSQuitAlwaysKeepsWindows -bool false
defaults write com.apple.iphonesimulator \
  ApplePersistenceIgnoreState -bool true
killall -TERM Simulator 2>/dev/null || true
killall -TERM SimMetalHost 2>/dev/null || true
killall -TERM SimRenderServer 2>/dev/null || true
```

Apple documents `FramebufferServerRendererPolicy=none` as the headless/CI mode
that skips compositing in CoreSimulator's virtual framebuffer. See the
[Xcode 11 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-11-release-notes).

Verify without launching Simulator:

```bash
defaults read com.apple.CoreSimulator FramebufferServerRendererPolicy
defaults read com.apple.iphonesimulator NSQuitAlwaysKeepsWindows
defaults read com.apple.iphonesimulator ApplePersistenceIgnoreState
pgrep -lf 'SimMetalHost|SimRenderServer|/Simulator.app/' || true
```

Expected values are `none`, `0`, and `1`, followed by no GPU-renderer process.

## Practical Development Route

- Build and archive from the command line without booting a simulator.
- Use one attached physical iPhone or iPad for visual and interaction QA.
- Keep simulator UI closed during signing, export, artifact audit, and store
  submission.
- Do not run concurrent simulators on the affected Intel graphics path.
- Preserve diagnostic reports privately; publish only redacted facts.

## Bound Background Analysis During Release Work

The same incident also had `mediaanalysisd` near 140 percent CPU for almost
three hours and `mds_stores` around 20-34 percent CPU. They were not the GPU
reset cause, but they increased thermal and scheduling pressure while Xcode
validated a protected installation.

For one bounded archive or upload, inspect the live process IDs, stop Photos
analysis, and lower Spotlight's priority:

```bash
media_pid="$(pgrep -x mediaanalysisd | head -n 1)"
mds_pid="$(pgrep -x mds_stores | head -n 1)"
test -z "$media_pid" || kill -STOP "$media_pid"
test -z "$mds_pid" || sudo renice 20 -p "$mds_pid"
```

Always restore normal behavior when the operation ends:

```bash
test -z "$media_pid" || kill -CONT "$media_pid"
test -z "$mds_pid" || sudo renice 0 -p "$mds_pid"
```

Do not store process IDs across reboots and do not leave `mediaanalysisd`
stopped permanently.

For store work, keep network isolation equally narrow. In the verified
EchoMind run, Google Play traffic used an ephemeral Ubuntu route limited to
Google OAuth and Android Publisher on TCP 443. The iOS path stayed on the Mac,
used `skip-simulator`, and did not launch the GPU renderer. VPN routing did not
cover Codex, SSH, the Mac, or unrelated traffic.

In the verified 2026-08-10 release window, the headless Mac path validated and
uploaded a 9,588,830-byte iOS/watchOS IPA without errors. Provider readback
reported the exact build `VALID`; no Simulator renderer launched and no new
GPU-reset report appeared. Photos analysis was resumed and Spotlight returned
to nice level 0 immediately afterward.

Restore the default renderer only for a deliberate bounded diagnostic:

```bash
xcrun simctl shutdown all
defaults delete com.apple.CoreSimulator FramebufferServerRendererPolicy
defaults delete com.apple.iphonesimulator ApplePersistenceIgnoreState
```

The next UI launch can reproduce the GPU reset. Return to headless mode when
the diagnostic ends.
