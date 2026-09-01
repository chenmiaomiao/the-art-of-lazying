# OptiPlex 7050 reboot and always-on report — 2026-09-01

## Executive summary

This workstation had both Windows Update restarts and a separate unclean
power/reset incident:

- Windows Update definitively initiated two planned restarts on 2026-08-30.
- The interruption before the 2026-09-01 boot was not an update, normal
  shutdown, sleep transition, or recorded blue-screen crash. Its exact physical
  cause is not logged; the evidence is most consistent with lost power, a reset,
  or a hard hang followed by reset.

The Windows-controlled cases are addressed by the reversible
[`Configure-WindowsAlwaysOn.ps1`](../scripts/Configure-WindowsAlwaysOn.ps1)
tool. Electrical and hardware causes require a UPS, cabling/power checks, and
possibly Dell BIOS AC-recovery configuration; software cannot guarantee
against them.

## Reboot evidence

All timestamps below are local time (`+08:00`).

| Time | Windows evidence | Finding |
| --- | --- | --- |
| 2026-08-30 08:55:07 | User32 event 1074, record 6601: `MoNotificationUx.exe` requested a planned restart for OS servicing. | Windows Update restart. |
| 2026-08-30 09:04:18 | User32 event 1074, record 6797: `TrustedInstaller.exe` requested a planned restart for OS upgrade. | Second Windows Update servicing restart. |
| 2026-08-30 09:05:29 | WindowsUpdateClient event 19 recorded successful installation of KB5121003/build 26200.9168 and KB5120708. | Confirms the two preceding restart causes. |
| 2026-08-30 14:20:52 | User32 event 1074, record 7043: `winlogon.exe`/SYSTEM initiated a clean power-off. | Planned shutdown, not a crash or automatic update restart. |
| 2026-09-01 08:22:19 | EventLog event 6008 reported that the previous operation ended unexpectedly. | Unclean loss/reset marker. |
| 2026-09-01 08:33:07–08:33:09 | Cold boot, Kernel-Power event 41, and no preceding event 1074/6006/Kernel-General 13. | Windows did not initiate or cleanly record this restart. |

The September 1 event 41 data had `BugcheckCode=0`,
`SleepInProgress=0`, `PowerButtonTimestamp=0`, no detected long power-button
press, and no WHEA boot error. There was no event 1001, MEMORY.DMP, minidump,
or time-correlated Windows Error Reporting blue-screen/LiveKernelEvent record.
Windows therefore cannot identify a more specific cause.

There were no sleep/resume events in the preceding 14 days. Historical unclean
shutdown markers also occurred twice on 2026-07-16, likewise without a
bugcheck.

## State before configuration

- Windows 11 Enterprise 25H2, build 26200.9168.
- Dell OptiPlex 7050, not joined to an Active Directory domain or MDM.
- Balanced power plan active.
- AC display and ordinary sleep timeout: already `0`.
- DC display timeout: 180 seconds; DC sleep timeout: 600 seconds.
- Console-lock display timeout: 60 seconds on AC and DC.
- Unattended sleep timeout: 120 seconds on AC and DC.
- Hybrid sleep: enabled in the plan; hibernation globally disabled.
- Current-user screen saver: enabled.
- Windows Update `NoAutoUpdate`: absent.
- `NoAutoRebootWithLoggedOnUsers=1`: present, but the update pause had expired
  on 2026-08-20 and did not prevent the two servicing restarts.
- Crash-control `AutoReboot=1`.
- No current CBS, Windows Update, or pending-file-rename reboot marker.

## Applied configuration

The tool creates an immutable first-run rollback snapshot, clones the current
power plan, and applies:

- zero AC/DC timeouts for display, console-lock display, sleep, unattended
  sleep, hibernate, and hybrid sleep;
- plan-independent machine policy for every supported display/sleep setting;
- hibernation off, current-user screen saver off, and machine inactivity lock
  off;
- Windows Update manual-only policy, update deadline policies off, update
  auto-restart off, and a Windows 11 25H2 target-version pin; and
- automatic reboot after a Windows bugcheck off.

The Windows Update, BITS, Orchestrator, and repair services are intentionally
left intact. Service activity alone does not mean automatic installation is
enabled.

## Verification result

The configuration completed successfully at `2026-09-01 09:37:24 +08:00`.
The first-run state and the independently repeated read-only status check
showed:

- `LazyingArt Always On` active with GUID
  `41920dc8-f6db-4465-b03a-b9536db5e716`;
- all six AC and DC display/sleep values equal to zero;
- hibernation, screen saver, and inactivity lock disabled;
- Windows Update `NoAutoUpdate=1` and `AUOptions=2`;
- `NoAutoRebootWithLoggedOnUsers=1` and
  `AlwaysAutoRebootAtScheduledTime=0`;
- product/version pinned to Windows 11 25H2;
- feature and quality update deadline flags both disabled;
- crash-control `AutoReboot=0`;
- no CBS, Windows Update, or pending-file-rename reboot marker; and
- `ConfigurationCompliant=true` and `SafeForUnattendedUptime=true`.

The computer-policy refresh returned exit code zero. Update-related services
remain available by design; their running state is not a verification failure.

The immutable rollback snapshot is:

```text
C:\ProgramData\LazyingArt\WindowsAlwaysOn\state-before-first-apply.json
```

It contains 25 scoped registry snapshots and records the original Balanced
plan GUID `381b4222-f694-41f0-9685-ff5bb260df2e`. Independent inspection
confirmed that it preserved the original screen-saver value `1`, crash
auto-reboot value `1`, and absence of `NoAutoUpdate` rather than overwriting
the first-run state.

## Remaining risk and next action

The policy would have prevented future automatic OS downloads/installs of the
kind that produced the August 30 restarts. It would **not** have prevented the
September 1 unclean incident: there was no running Windows shutdown path to
cancel.

For that remaining class of failure:

1. Check the AC cable, power strip, and Dell power connector seating.
2. Use a UPS if power continuity matters.
3. Set Dell BIOS AC Recovery to Power On or Last State.
4. If another event 41/6008 occurs, record the wall-clock time and whether the
   screen froze or power disappeared; then check PSU, thermals, RAM, and storage.

Disabling automatic OS updates is a security tradeoff. Perform deliberate
manual maintenance regularly and keep Defender intelligence current.
