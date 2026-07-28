# OptiPlex 3040 Windows 11 25H2 Staging

Status date: 2026-07-28

## Decision

The Dell OptiPlex 3040 has an Intel Core i7-6700. Microsoft's current Windows
11 Intel processor list does not include this sixth-generation CPU. Treat the
machine as unsupported even if TPM, UEFI, Secure Boot, memory, and storage
checks pass.

Microsoft's current download for an existing PC is Windows 11 25H2. Windows
11 26H1 is for selected new devices and is not the in-place successor to
24H2 or 25H2. Do not stage an Installation Assistant: running it can proceed
into installation and restart. Use the official x64 ISO so preparation
remains a set of inert files.

References:

- <https://www.microsoft.com/en-us/software-download/windows11>
- <https://learn.microsoft.com/windows/release-health/windows11-release-information>
- <https://learn.microsoft.com/windows-hardware/design/minimum/supported/windows-11-supported-intel-processors>
- <https://support.microsoft.com/windows/windows-11-on-devices-that-don-t-meet-minimum-system-requirements>

## Audited Storage Model

Reconfirm this layout from the running Windows 10 installation:

- 256 GB Samsung SSD: Windows 10 and macOS system storage;
- 1 TB Toshiba disk: data, legacy Windows 7 files, and the `MACRECOVERY` ESP.

Drive letters are not identities and may change. The preparation script
accepts a destination drive letter only after proving that:

- it is not `%SystemDrive%`;
- it is not on the Windows system disk;
- its physical disk is at least 800 GB;
- its physical disk is not larger than 1.2 TB.

The intended location is:

```text
<data-drive>:\UpgradeKits\Windows11-25H2
```

Do not use the Windows 10 partition, the macOS APFS partition, the
`MACRECOVERY` ESP, or the legacy Windows 7 volume.

## Phase 1: Read-only Audit

Open Windows PowerShell as Administrator:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Get-Optiplex3040Windows11Readiness.ps1 `
  -OutputDirectory 'E:\UpgradeKits\Windows11-25H2\reports'
```

Replace `E:` only after checking `Get-Disk`, `Get-Partition`, and `Get-Volume`.
The script inventories the model, BIOS mode, CPU, TPM, Secure Boot, memory,
system disk, data volumes, BitLocker state, pending reboot indicators, active
Windows Setup processes, and common automatic-start locations. It writes a
text report and JSON report only when `-OutputDirectory` is supplied.

The i7-6700 CPU result is intentionally `Unsupported`. Do not rewrite that
result based on an unofficial compatibility list.

Source:
[Get-Optiplex3040Windows11Readiness.ps1](./scripts/Get-Optiplex3040Windows11Readiness.ps1)

## Phase 2: Create an Inert Kit

Copy this directory to Windows, then run:

```powershell
.\Initialize-Optiplex3040Windows11Kit.ps1 -DestinationDrive E
```

The initializer validates the destination's physical disk, creates the kit
directory, copies the scripts, writes an official-download shortcut and a
`DO-NOT-RUN.txt` marker, and performs the readiness audit. It does not
download, mount, or execute installation media.

Source:
[Initialize-Optiplex3040Windows11Kit.ps1](./scripts/Initialize-Optiplex3040Windows11Kit.ps1)

## Phase 3: Download and Register the ISO

Use only Microsoft's Windows 11 download page. Select:

```text
Windows 11 25H2
x64
the same display language as the installed Windows 10 system
```

Save the ISO directly under the kit's `media` directory. Microsoft displays a
SHA-256 value in its download verification section. Record that exact value,
then register the ISO:

```powershell
.\Register-Windows11Iso.ps1 `
  -KitRoot 'E:\UpgradeKits\Windows11-25H2' `
  -IsoPath 'E:\UpgradeKits\Windows11-25H2\media\Windows11_25H2_English_x64.iso' `
  -MicrosoftSha256 '<64-hex-value-from-Microsoft>'
```

Registration fails on a hash mismatch. It writes a manifest but does not
mount the image. The ISO file is never trusted merely because its filename
looks official.

Source:
[Register-Windows11Iso.ps1](./scripts/Register-Windows11Iso.ps1)

## No-auto-start Proof

Run the audit again and inspect these fields:

```text
ActiveSetupProcesses
AutomaticStartEntries
PendingRebootIndicators
```

The kit has no scheduled task, service, `Run`, `RunOnce`, BCD entry, firmware
variable, or Windows Update target policy. Merely storing an ISO cannot start
Windows Setup.

Do not:

- open the ISO from Explorer while AutoPlay is enabled;
- run Windows 11 Installation Assistant;
- use `/SkipFinalize`, which deliberately stages Setup internals;
- set `BootNext` or change the OpenCore/Windows boot order;
- create a Windows Update product-version policy for Windows 11.

## Future Attended Upgrade

Preparation stops here. Before a future upgrade:

1. Boot Windows 10 through the tested OpenCore picker.
2. Back up the Windows 10 volume, EFI trees, GPT headers, and recovery keys.
3. Disconnect unnecessary external disks.
4. Confirm Windows activation and at least 40 GB free on `%SystemDrive%`.
5. Confirm the ISO language and edition match the installed Windows system.
6. Run Microsoft's compatibility scan from the mounted ISO.
7. Review the Setup compatibility logs and the unsupported-hardware warning.
8. Decide explicitly whether to continue on unsupported hardware.

Microsoft documents `/Compat ScanOnly` as a scan that exits without
installing. A future attended scan can use:

```powershell
<mounted-drive>:\setup.exe /auto upgrade /compat scanonly /dynamicupdate disable
```

Do not use `/Quiet`, `/Eula accept`, `/NoReboot`, `/SkipFinalize`, or an
unsupported-hardware bypass during preparation. No upgrade launcher is
included intentionally: the action that can replace the operating system
must remain visibly attended.

## Rollback Record

Before any future launch, preserve:

- `Get-ComputerInfo`, `Get-Disk`, `Get-Partition`, and `Get-Volume` reports;
- `bcdedit /enum all`;
- `manage-bde -status`;
- Dell BIOS settings and current boot-mode photos;
- the accepted OpenCore EFI manifest and backup;
- Windows product edition, display language, and activation status;
- the Windows 11 ISO SHA-256 and Microsoft download date.

Keep these records on the 1 TB data disk and a second machine. A backup on the
same physical disk is not a disaster-recovery copy.
