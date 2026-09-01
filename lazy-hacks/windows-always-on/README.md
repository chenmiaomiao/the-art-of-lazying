# Windows always-on and manual-update workstation

This workflow keeps a Windows 10/11 workstation awake and visible, makes
Windows operating-system updates manual-only, and blocks Windows-controlled
automatic restarts. It is intended for remotely accessed desktops that must
remain reachable.

It cannot prevent a restart caused by lost mains power, a hardware reset,
firmware, thermal protection, a total system hang, or an explicit restart from
a user or application. See the
[2026-09-01 OptiPlex 7050 report](./reports/2026-09-01-optiplex-7050-reboot-report.md)
for a real example of the difference.

## Quick start

The status check is read-only and does not need elevation:

```powershell
cd C:\Users\Administrator\Projects\the-art-of-lazying
.\lazy-hacks\windows-always-on\scripts\Configure-WindowsAlwaysOn.ps1 -Mode Status
```

Apply the configuration:

```powershell
.\lazy-hacks\windows-always-on\scripts\Configure-WindowsAlwaysOn.ps1 -Mode Apply
```

Accept the single UAC prompt. The elevated worker is hidden, so it does not
leave a terminal window on the desktop. The first run preserves an exact
rollback snapshot under:

```text
C:\ProgramData\LazyingArt\WindowsAlwaysOn\state-before-first-apply.json
```

Repeated `Apply` runs are idempotent and do not overwrite that first snapshot.

Restore the recorded pre-apply state:

```powershell
.\lazy-hacks\windows-always-on\scripts\Configure-WindowsAlwaysOn.ps1 -Mode Restore
```

## What Apply changes

| Area | Result |
| --- | --- |
| Display | Normal and console-lock display timeouts are `0` on AC and DC power. |
| Sleep | Idle sleep, unattended sleep, hibernate timeout, and hybrid sleep are `0` on AC and DC. |
| Power plan | A dedicated `LazyingArt Always On` clone is activated; the previous plan is preserved for rollback. |
| Hibernate | Hibernation is disabled with `powercfg /hibernate off`. |
| Screen saver | The current user's screen saver and inactivity lock are disabled. |
| Windows Update | `NoAutoUpdate=1` makes OS updates manual-only; deadline policies are disabled. |
| Feature upgrade | Windows is pinned to the product and display version installed at apply time. |
| Restart | Windows Update automatic-restart policies are disabled. |
| Crash | Automatic reboot after a Windows bugcheck is disabled so the failure remains visible for diagnosis. |

The tool also enforces the standard display/sleep values through machine power
policy, so switching ordinary power plans does not silently restore timers.
The hidden console-lock timer is set in the dedicated plan because this Windows
build does not expose a matching Administrative Template policy.

The tool deliberately does **not** disable or damage `wuauserv`, Update
Orchestrator, BITS, WaaSMedic, task ACLs, or `SoftwareDistribution`. Those
components remain available for deliberate Windows Update checks and repair.

## Manual update window

Automatic OS patching is disabled, which increases security risk if updates
are ignored. Choose a maintenance time—monthly is a reasonable baseline—and
open Windows Update yourself:

```powershell
Start-Process 'ms-settings:windowsupdate'
```

Click **Check for updates**, approve the download/install, and restart only
when you are ready. Run `-Mode Apply` again afterward to reassert the always-on
settings and pin the newly installed display version.

Microsoft Defender intelligence, Microsoft Store apps, Edge, Office, firmware,
and third-party tools have separate update paths. This workflow does not stop
those mechanisms; they normally do not control Windows Update reboot policy.

## Reboot and shutdown evidence

Create a read-only JSON event report:

```powershell
.\lazy-hacks\windows-always-on\scripts\Get-WindowsRestartEvidence.ps1 `
  -Days 30 `
  -OutputPath "$env:TEMP\windows-restart-evidence.json"
```

Useful interpretations:

- User32 event `1074` identifies a planned restart or shutdown and names the
  initiating process.
- Kernel-Power event `41` plus EventLog event `6008` means the prior shutdown
  was unclean. It does not prove whether the cause was power loss, a reset, or
  a hard hang.
- Kernel-Power event `42` and Power-Troubleshooter event `1` identify sleep and
  resume.
- A bugcheck code of zero with no dump is not evidence of a blue-screen crash.

## Rollback details

`Restore` performs a scoped rollback:

1. Restore every managed registry value to its original data, or remove it if
   it did not exist.
2. Restore the original hibernation state.
3. Reactivate the original power plan.
4. Delete only the power-plan clone created by this tool.

It never calls `powercfg /restoredefaultschemes`, because that would destroy
unrelated custom plans. Do not edit or publish the JSON files in
`C:\ProgramData\LazyingArt\WindowsAlwaysOn`; they are machine-specific
rollback and verification state.

## Failure boundaries

- `CrashControl\AutoReboot=0` leaves the computer stopped at a blue screen
  instead of rebooting. This aids diagnosis but can reduce remote availability.
- Disabling hibernation also disables Windows Fast Startup.
- Never blanking or sleeping increases electricity use, panel wear, and heat.
- AC loss still turns the computer off. Use a UPS and set Dell BIOS **AC
  Recovery** to **Power On** or **Last State** if unattended recovery matters.
- A hard lock can require a physical or remote power-cycle. Windows cannot
  cancel a reset after the operating system has stopped running.
- Organization policy can supersede local policy. This computer was not domain
  or MDM joined when the workflow was applied.

## Official basis

- [Powercfg command-line options](https://learn.microsoft.com/windows-hardware/design/device-experiences/powercfg-command-line-options)
- [Manage Windows Update settings](https://learn.microsoft.com/windows/deployment/update/waas-wu-settings)
- [Windows Update policy CSP](https://learn.microsoft.com/windows/client-management/mdm/policy-csp-update)
- [Windows OS recovery configuration](https://learn.microsoft.com/windows/win32/cimwin32prov/win32-osrecoveryconfiguration)
