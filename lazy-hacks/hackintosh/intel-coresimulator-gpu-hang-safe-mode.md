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
reported the exact build `VALID`; the guarded public-beta workflow then
attached it and read back `APPROVED` with the existing public TestFlight link
enabled. Formal App Store submission remained a separate closed gate. No
Simulator renderer launched and no new GPU-reset report appeared. Photos
analysis was resumed and Spotlight returned to nice level 0 immediately
afterward.

More than five hours after reboot, a second read-only check still showed zero
booted simulators, no Simulator UI or renderer, about 48 GiB free, and no
active Xcode build or device-diagnostic job. Keep that headless state while
using App Store Connect APIs and physical devices.

## SSH Signing Is An Audit-Session Problem

After reboot, an SSH process may see valid development identities while
`codesign` still fails with `errSecInternalComponent`. First unlock the login
keychain and restore the signing partition list interactively. If direct SSH
signing still fails, run the bounded build inside the already logged-in GUI
audit session and drop privileges back to the console user:

```bash
console_user="$(stat -f '%Su' /dev/console)"
console_uid="$(id -u "$console_user")"

sudo launchctl asuser "$console_uid" \
  sudo -u "$console_user" env \
    HOME="/Users/$console_user" \
    DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer \
    xcodebuild <physical-device arguments>
```

This recovered signing for a physical iPad build without opening Simulator.
The subsequent XCTest stopped because iPadOS timed out while enabling UI
Automation; that is a device setup gate, not evidence that the graphics path
is healthy enough to retry Simulator.

Also watch for Xcode's failure diagnostics. A failed physical UI test may leave
`xcodebuild` waiting on a ten-minute `devicectl diagnose` process. Inspect and
end only that failed process tree, remove the temporary test runner, and restore
any temporarily adjusted `mediaanalysisd` or `mds_stores` priority before the
next release operation.

## Repair A Stale Developer Directory After Reboot

If `xcrun` suddenly reports a missing `DEVELOPER_DIR`, verify the selected path
before reinstalling Xcode. In the validated incident, `xcode-select` retained a
path to a removed Xcode 26.6 bundle while the complete Xcode 26.3 application
was still present.

```bash
xcode-select -p
find /Applications -maxdepth 1 -type d -name 'Xcode*.app' -print
/Applications/Xcode-26.3.0.app/Contents/Developer/usr/bin/xcodebuild -version

sudo xcode-select --switch \
  /Applications/Xcode-26.3.0.app/Contents/Developer
xcrun simctl shutdown all
```

Recheck the three renderer defaults and confirm zero booted devices. Idle
CoreSimulator registration services are not equivalent to a booted virtual
device; keep the UI and Metal renderer closed.

## Recover After Another Frozen Loading Screen

Do not reopen the UI just to test whether the reboot fixed it. In a later
verified recovery, LAN SSH remained healthy and the host had no booted virtual
device or active Metal renderer, although two stale CoreSimulator service
trees had re-registered. The bounded recovery was:

```bash
xcrun simctl shutdown all
killall Simulator SimMetalHost SimRenderServer \
  com.apple.CoreSimulator.CoreSimulatorService \
  SimLaunchHost.x86 SimulatorTrampoline 2>/dev/null || true
```

Then verify the renderer defaults and query only boot state. `simctl` may
restart idle CoreSimulator registration helpers; this is expected. The
failure boundary is a booted device, Simulator UI, or active renderer.

In that recovery, the machine still had exactly four historical GPU-reset
reports and no new report for the latest stalled loading screen. Absence of a
new report is not proof that the unsupported graphics path is stable. Continue
with command-line builds and physical devices.

## Route One Phone Operation, Then Remove It

An external test phone needs source-scoped routing at the router because a
local process namespace cannot classify traffic that originates on another LAN
device. The reusable `astrill-lazy device-flow` command therefore requires:

- one exact IPv4 host rather than a subnet;
- the router-observed MAC address;
- explicit destination domains rather than wildcards;
- an explicit TCP/UDP port; and
- one owner ID used for compare-and-swap deletion.

The EchoMind verification routed only the Play endpoints observed in phone
logs on port 443. The genuine internal-testing listing then loaded, and the
owner-scoped overlay was removed with an empty readback. The overlay never
classified Codex, SSH, Ubuntu, the Mac, or another client. A later audit did,
however, find the native Astrill website policy in global mode. That separate
default could still tunnel unmatched traffic. Back up the native site policy,
set it to Direct-by-default include mode when task-only routing is intended,
reconnect through the companion, and verify ordinary egress independently.
Shared CDN IP addresses remain an IP-layer limitation, so keep the domain list
minimal and the overlay lifetime short.

The deeper physical-device result is documented in
[`../networking/google-play-scoped-device-delivery.md`](../networking/google-play-scoped-device-delivery.md).
The internal candidate and tester entitlement were valid, but the China-local
signed CDN path did not complete a Play-signed install. That provider-delivery
failure remains an open QA gate and is not evidence that the app binary failed.

Restore the default renderer only for a deliberate bounded diagnostic:

```bash
xcrun simctl shutdown all
defaults delete com.apple.CoreSimulator FramebufferServerRendererPolicy
defaults delete com.apple.iphonesimulator ApplePersistenceIgnoreState
```

The next UI launch can reproduce the GPU reset. Return to headless mode when
the diagnostic ends.
