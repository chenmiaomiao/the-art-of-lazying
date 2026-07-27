# Safely Upgrade the UU Remote Ubuntu Bridge

This is the short operational runbook for updating an already working
[UU Remote Ubuntu Bridge](./uu-remote-ubuntu-bridge.md) without losing the UU
login, the host-specific keyboard route, XRDP, or the last known-good Wine
prefix.

The bridge source and the proprietary UU product are two separate layers:

| Layer | Normal update | Safety boundary |
| --- | --- | --- |
| Public bridge source | Fast-forward Git and reinstall the current helpers | Preserve the existing environment, keyring credential, prefix, and behavior track |
| Windows UU product in Wine | Promote only an exact installer hash with a committed acceptance record | Snapshot the complete prefix, compare account state, verify twice, and roll back on any failure |

Do not replace `GameViewerServer.exe`, run a newly downloaded installer over
the production prefix, or copy another computer's prefix by hand.

## Current production truth

As recorded on 2026-07-27:

- the production client is the approved UU Remote `4.33.0.8907`;
- `4.34.0.8979` has a statically reviewed patch, but its former promotion
  acceptance is withdrawn;
- a guarded 4.34 warm promotion preserved login, XRDP, and input settings;
- a later stopped-prefix cold start stalled before fresh signaling;
- restoring the complete 4.33 snapshot reproduced the same stall;
- the real shared cause was accumulated Wine device-registry state, not simply
  the 4.34 executable;
- `uu-remote repair-registry` removed only the audited stale virtual-input and
  Wine Bluetooth observations and restored a fast cold start.

Because the 4.34 manifest no longer contains an acceptance object, the upgrade
transaction must refuse to promote it. Re-acceptance requires a new
stopped-prefix cold start, fresh signaling room, controller input, login
preservation, and stability test.

## Routine read-only check

Start here:

```bash
uu-remote status
uu-remote upgrade status
uu-remote upgrade check
```

`check` may fast-forward clean public source and run tests, but it must not
install an unknown or unaccepted UU product. If the checkout is dirty,
detached, or divergent, stop and inspect it rather than forcing Git.

The source-tree form is available if `~/.local/bin` is missing from `PATH`:

```bash
cd ~/ProjectsLFS/uu-remote-ubuntu-bridge
git status --short --branch
./scripts/upgrade-uu-remote.sh check
```

## Apply an accepted upgrade

Use the normal idle-aware transaction:

```bash
uu-remote upgrade apply
```

Only when a brief, deliberate UU interruption is acceptable:

```bash
uu-remote upgrade apply --now
```

`--now` bypasses only the configured idle delay. It does **not** bypass:

- the official installer SHA-256;
- the committed, hash-bound acceptance record;
- the complete Wine-prefix snapshot;
- byte-for-byte UU account-state comparison;
- the approved compatibility manifest;
- the current relay and input-route checks;
- the two post-start runtime checks;
- the requirement that XRDP retain its original active state; or
- automatic rollback.

The transaction intentionally does not start, stop, restart, or reconfigure
XRDP.

## What the transaction preserves

The installer reads and writes back
`~/.config/uu-remote-bridge/environment`. On the direct-X11 workstation this
included:

```text
UURB_TEXT_KEY_DELAY_MS=8
UURB_PHYSICAL_KEY_DELAY_MS=0
UURB_KEYBOARD_ROUTE=x11
UURB_NETWORK_INTERFACE=default
```

Those values describe one validated host. Do not copy them to a different
computer that uses the RDP-broker track.

Private rollback state remains local:

```text
~/.local/state/uu-remote-updater/tasks/*/promotion/snapshot-prefix
~/.local/state/uu-remote-upgrader/transactions/TIMESTAMP/
~/.local/state/uu-remote-upgrader/latest
```

These paths may contain proprietary binaries, local settings, and account
evidence. Never commit or transfer them.

## Post-upgrade acceptance

First run the content-free checks:

```bash
uu-remote status
cd ~/ProjectsLFS/uu-remote-ubuntu-bridge
./scripts/verify.sh --quick
```

Then reconnect through UU and visibly test both controller input paths:

```text
phone keyboard: abcXYZ123,.!?
computer keyboard: rapid alphabet, Enter, Ctrl+A
mouse: move, click, drag, and wheel
disconnect and reconnect once
```

An RDP-only test does not prove that the UU controller route works.

If the controller remains at **finding routes**, do not immediately blame DNS
or reinstall UU. Diagnose the current service start:

```bash
uu-remote status
uu-remote logs
uu-remote repair-registry
```

The repair is bounded, prefix-local, backed up, and idempotent. Full evidence
is in
[Repair UU Remote Stuck at “Finding Routes”](./uu-remote-finding-routes-wine-registry-repair.md).

## Automatic maintenance policy

The conservative production configuration checks daily but does not mutate a
healthy relay:

```bash
cd ~/ProjectsLFS/uu-remote-ubuntu-bridge
./scripts/configure-updater.sh enable \
  --track track-direct-x11-20260724 \
  --model codex-auto-review \
  --reasoning-effort medium \
  --no-auto-reinstall \
  --no-auto-promote
./scripts/configure-updater.sh status
```

Use `track-rdp-broker-20260724` on the other validated host. The daily checker
can inspect an upstream release and prepare a private repair task, but Codex
cannot approve its own binary analysis, push from the repair clone, or deploy
an unknown installer.

## Detailed implementation record

The complete transaction order, rollback phases, persistent user-bus handling,
reproducible PE verifier lesson, readiness race, and cross-computer handoff
live in the bridge repository:

- [Reusable, login-preserving upgrade](../../code/uu-remote-ubuntu-bridge/docs/reusable-upgrade.md)
- [Automatic checks and resumable repair](../../code/uu-remote-ubuntu-bridge/docs/automatic-updates.md)
- [4.34 withdrawn acceptance record](../../code/uu-remote-ubuntu-bridge/docs/releases/4.34.0.8979-acceptance.md)
