# Repair UU Remote Stuck at “Finding Routes” on Ubuntu/Wine

## Result

On 2026-07-27, the Ubuntu UU Remote bridge could be selected from a
controller, but the controller remained indefinitely at **finding routes**.
The host was online and XRDP was healthy. The failure happened before UU
started transport-route selection: `GameViewerServer.exe` was synchronously
walking a very large device registry and had not yet created its signaling
room.

The durable repair is included in
[`uu-remote-ubuntu-bridge`](../../code/uu-remote-ubuntu-bridge). For an
installed current bridge, the safe operator command is:

```bash
uu-remote repair-registry
cd ~/ProjectsLFS/uu-remote-ubuntu-bridge
./scripts/verify.sh --quick
```

The repair is idempotent and transactional. It restarts only
`uu-remote-bridge.service`; it does not restart, reload, or reconfigure XRDP.

## What “Finding Routes” Meant in This Incident

The controller wording suggested DNS, Ethernet, Wi-Fi, firewall, NAT, or relay
selection. The newest host log instead stopped here:

```text
update_gvinput start
```

It did not contain either of the startup milestones:

```text
update_gvinput end
room_state_changed: created
```

UU had therefore not reached its signaling-room boundary. Route changes could
not repair a startup stage that had not yet attempted route selection.

`GameViewerServer.exe` used about 190% CPU while apparently doing nothing.
This was useful evidence: it was a local synchronous scan, not a blocked
network wait.

## Root Cause

The dedicated, long-lived UU Wine prefix had accumulated:

- 527 stale `ROOT\HIDCLASS` virtual `gvinput` devices;
- 518 matching fake mouse devices;
- 1,044 matching `gvinput.inf` and `gvinputmf.inf` class instances;
- 21,894 `WINEBTH\DEVICE` roots, represented by 87,582 registry sections.

The host had only 29 current Linux input entries under `/sys/class/input`.
Wine had retained Bluetooth addresses observed while host discovery was
active, while repeated attempts to install UU's unsupported Windows virtual
input driver had retained failed devices. UU scanned all of this state before
joining its signaling room.

The Wine `system.reg` file had grown to 34,389,195 bytes. After the scoped
repair it was about 3.9 MB.

## Why a Product Rollback Alone Did Not Fix It

UU 4.34.0.8979 had passed warm file, login, relay, and runtime checks, but a
later production cold start exposed the stall. The complete preserved 4.33
prefix was restored atomically, and XRDP kept the same process throughout.

The exact known-good 4.33.0.8907 runtime then reproduced the high-CPU scan on
its next cold start. That disproved the initial theory that only the 4.34
binary was bad. Both releases were reading the same accumulated Wine state.

Version 4.34's acceptance was therefore withdrawn. Its binary patch remains
statically reviewed, but its manifest has no promotion `acceptance` object and
cannot be auto-promoted until a new stopped-prefix cold-start test succeeds.

## Repair Design

The permanent implementation has four boundaries:

1. `scripts/inspect-wine-device-registry.py` classifies the dedicated prefix
   and builds an exact deletion plan.
2. `scripts/clean-wine-device-registry` stops that Wine prefix, performs a
   fail-closed preflight, and keeps a mode-0600 `system.reg` backup.
3. The installer makes only the audited UU `devcon.exe` unavailable and
   retains the exact vendor file as `devcon.exe.uu-original`.
4. Wine Bluetooth enumeration is disabled only inside UU's dedicated prefix;
   Ubuntu Bluetooth is unchanged.

The cleaner removes only recognized UU artifacts:

- stale `WINEBTH\DEVICE` observations;
- stale NetEase `gvinput` HID and mouse roots;
- matching `gvinput.inf` and `gvinputmf.inf` class instances;
- the unsupported `gvinput` and `gvinputmf` Wine services.

It refuses broad `ROOT\HIDCLASS` or `ROOT\MOUSE` cleanup if an unrelated
device shares either subtree. If any mutation or verification step fails, it
restores the registry backup before returning failure.

Do not copy this cleanup to a shared Wine prefix and do not manually delete
arbitrary HID registry keys. Its safety assumptions depend on the project
owning a dedicated UU-only prefix.

## Verification

Inspect the prefix without changing it:

```bash
~/.local/libexec/uu-inspect-wine-device-registry.py inspect \
  ~/.local/share/wineprefixes/uu-remote
```

A healthy result includes:

```json
{
  "clean": true,
  "gvinput_hid_roots": 0,
  "gvinput_mouse_roots": 0,
  "winebth_devices": 0,
  "winebth_start": 4
}
```

Static `WINEBTH\RADIO` metadata may be recreated by Wine and is allowed.
Accumulated `WINEBTH\DEVICE` roots are not.

The bridge verifier now rejects a service start unless the newest server log
was created after that service start and contains both:

```text
update_gvinput end
room_state_changed: created
```

Inspect the same privacy-safe milestones manually:

```bash
server_logs="$HOME/.local/share/wineprefixes/uu-remote/drive_c/Program Files/Netease/GameViewer/log/server/log"
latest="$(
  find "$server_logs" -maxdepth 1 -type f -name 'log_*.txt' \
    -printf '%T@ %p\n' |
  sort -nr |
  head -n 1 |
  cut -d' ' -f2-
)"
rg 'update_gvinput|input_device_count|room_state_changed: created' "$latest"
```

The repaired workstation produced:

- `input_device_count:0`;
- `update_gvinput start` to `end` in about 4–9 ms;
- `room_state_changed: created` about four seconds after startup;
- zero stale Bluetooth device roots on two consecutive cold starts;
- the existing UU account and input profile unchanged;
- the existing XRDP process unchanged.

The final proof still requires reconnecting from a real UU controller. Host
signaling proves that startup reached the route boundary; only the controller
can prove the complete controller-to-host session.

## Backup and Recovery

Each mutation keeps its own private backup under:

```text
~/.local/share/wineprefixes/uu-remote/compat/registry-backups/
```

The filename starts with:

```text
system.reg.before-device-hygiene-
```

The cleaner restores it automatically if verification fails. A full
product-promotion transaction separately keeps a complete prefix snapshot, so
binary rollback and registry rollback remain distinct.

Do not restore `system.reg` while any process from the prefix is running.
Prefer rerunning the audited command or using the repository's documented
rollback procedure instead of manually copying registry files.

## Safe Update Policy

A warm canary proves that an already-running process survived. It does not
prove startup-only driver and device enumeration. Future acceptance requires:

1. a fully stopped staging prefix;
2. prefix-local device hygiene;
3. a fresh `update_gvinput end`;
4. a fresh `room_state_changed: created`;
5. real controller reconnect and input;
6. login-state preservation;
7. the normal stability interval.

The conservative production updater configuration keeps live mutations off:

```bash
./scripts/configure-updater.sh enable \
  --track track-direct-x11-20260724 \
  --model codex-auto-review \
  --reasoning-effort medium \
  --no-auto-reinstall \
  --no-auto-promote
```

Daily metadata checks and private repair analysis may continue, but they do
not transfer a candidate into the live prefix. Promotion should occur only
after the exact release carries complete, hash-bound acceptance evidence.

## Reusable Lessons

- Diagnose the stage behind a UI message before changing the network.
- Compare a failing new build with the exact old build against the same state.
- Treat a warm check and a stopped-prefix cold start as different tests.
- A no-op driver installer is not equivalent to an unavailable driver:
  returning fake success made UU wait for a device that could never appear.
- Keep registry cleanup prefix-local, audited, reversible, and fail-closed.
- Preserve a known-good binary snapshot, but investigate mutable state when
  rollback reproduces the same failure.
- Keep unrelated remote access alive during repair. Here XRDP was the control
  path and was never restarted.

