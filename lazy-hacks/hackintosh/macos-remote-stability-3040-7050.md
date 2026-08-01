# OptiPlex 3040 and 7050 macOS Stability

This runbook records the 2026-07-28 investigation of intermittent remote
desktop stalls on the OptiPlex 3040 Monterey and OptiPlex 7050 Sequoia
Hackintoshes. It separates a real macOS crash from an alive but overloaded
desktop before changing OpenCore.

## Conclusion

The initial audit found no conventional kernel, GPU-restart, power, or memory
crash on either Mac. A later protected-log review found recurrent framebuffer
transaction hangs on the 3040; those events do not create a conventional GPU
restart or panic report.
The 7050 remained responsive after the controls below were installed: SSH,
VNC, WindowServer, and all expected UU processes stayed up while the covered
iCloud and Photos workers settled to zero or near-zero CPU.

| Evidence | OptiPlex 3040 | OptiPlex 7050 |
| --- | --- | --- |
| Last shutdown cause | Software initiated | Software initiated |
| Panic, watchdog, GPU restart, or WindowServer report | None found | None found |
| Intel HD 530 acceleration and active display | Accelerated, but Kaby-spoofed with recurring transaction hangs | Healthy |
| Memory pressure, compression, and swap | Healthy | Healthy |
| SMART status | Verified | Verified |
| Sleep/wake cycles | None | None |
| APFS free space | About 89 GiB | About 15 GiB |
| SATA command errors | None found | Continuous on optical-drive port 1 |
| Persistent background load | None | iCloud Drive and Photos analysis |
| UU Remote resource reports | Excessive wakeups | Excessive wakeups |

During the initial audit, the 3040 was healthy after its software restart.
Its visible anomaly at that point was UU Remote exceeding macOS's wakeup-rate
threshold. Two reports measured 45,001 wakeups in 196 and 50 seconds, or
approximately 230 and 908 wakeups per second. macOS recorded the reports but
took no action. The later HD 530 evidence is recorded separately below.

Later in the same maintenance window, the 3040 stopped answering ping, SSH,
and VNC and did not reappear at another LAN address. That state cannot be
classified remotely as a kernel lock, power-off, failed boot, or network
failure. Its next successful boot must be audited before any EFI change. The
7050 was deliberately left online while the 3040 was unavailable.

The 7050 had three simultaneous sources of pressure:

1. `AppleAHCIPort` aborted a command on SATA port 1 every second with error
   `0xe0030005`. I/O Registry mapped port 1 to the empty HL-DT-ST optical
   drive. The Micron SSD is port 0; its I/O counters showed zero read errors,
   write errors, and retries, and SMART remained Verified.
2. `fileproviderd` and then `bird` used roughly 100-150 percent CPU while
   iCloud Drive refreshed its FileProvider database. A process sample showed
   `BRCCloudDocsAppsMonitor` refetching applications and sustained SQLite
   activity. No FileProvider fault or database-corruption message was found.
3. `mediaanalysisd` used roughly 90-130 percent CPU and about 1.3 GiB while
   Photos performed full-frame video, face, object, motion, and scene
   analysis.

The 7050 also had only about 15 GiB free. Its current Sequoia Data volume used
about 140 GiB and the retained Monterey System and Data volumes used about
58 GiB. Xcode developer data used another 21 GiB within the current Data
volume.

A suspended automatic major update to Tahoe 26.5.2 had an MSU preparation
snapshot on the current Sequoia volume. It was not the apparent 12 GiB
reported by an initial `du`: that command crossed into the mounted system
snapshot at `/System/Volumes/Update/mnt1`. Same-filesystem accounting showed
only 73 MiB on the Update volume and 221 MiB in `/Library/Updates`. The
combination of genuinely low APFS free space and sustained iCloud and Photos
work explains a desktop that feels frozen while SSH, VNC, WindowServer, and
UU Remote remain alive.

Do not delete `/System/Volumes/Update` or its non-purgeable APFS snapshot by
hand. The supported `softwareupdate` CLI has no cancel-staged-update command,
and manually removing protected update state risks the current boot volume.

## 2026-08-01 7050 Hard-Freeze Follow-up

Later evidence supersedes the earlier tentative classification. The guard
recorded 1 GiB free at 01:01 and 0 GiB free from 01:05 through 01:44:58. The
unified log stopped at 01:58:42 and did not resume until the physical reboot at
15:40. There was no panic. The final three minutes contained 2,549 `rapportd`
and 1,089 `airportd` records on a machine with Ethernet but no Wi-Fi hardware
port. APFS exhaustion is the verified primary trigger; the Ethernet-only
Continuity/CoreWLAN storm is a verified terminal amplifier.

The reversible Ethernet-only policy now disables per-user `rapportd`,
`sharingd`, and `bluetoothuserd`, Handoff, AirDrop, and application relaunch.
After `brctl status` reported the main CloudDocs container caught-up and
consistent, it also disabled per-user `bird` and `FileProvider` at the owner's
request. Photos remains enabled with optimized storage. Machine identity is
read from a private mode-600 configuration rather than committed to Git.

The guard still warns below 25 GiB. It now shuts down Simulator devices below
15 GiB and, below 8 GiB, performs a six-hour-cooldown cleanup limited to
reproducible developer/cache data. It never deletes projects, cloud documents,
Codex state, UU state, simulator runtimes, or APFS volumes.

An explicit cleanup reclaimed about 16.6 GiB from the active Sequoia account.
A second guarded cleanup removed the obsolete Sequoia installer, stale sleep
image, migration leftovers, and caches from the Monterey fallback, reclaiming
17,441 MiB. Shared APFS free space then held at 46.2 GiB over a five-sample
remote-service check. Monterey 12.7.6, its account, SSH, and UU state remain.

A final allow-listed pass removed CloudKit cache and closed GlassAgent logs.
The authoritative APFS result was 188.2 GB used and 52.1 GB free (about 48.5
GiB). Directory cleanup totals can differ from APFS free-space movement while
the operating system allocates data concurrently.

The fallback Data volume has a repeatable APFS directory-statistics mismatch.
Live verification exits successfully but defers repair because Sequoia shares
the mounted container. Run Disk Utility First Aid from Recovery during a
planned maintenance window; do not erase the fallback or change EFI for this
metadata warning.

The reusable Recovery helper is
`scripts/repair-optiplex-7050-apfs-from-recovery.sh`. It takes explicit
`--container diskN` and `--data diskNsN` arguments because Recovery disk
numbers are not stable. It validates membership and the APFS Data role, checks
all command paths, refuses the active root, avoids forced unmounts, and logs
repair plus post-repair verification under `/tmp`.
Copy the script itself to `/tmp` before running it so unmounting the target
container cannot remove the script source midway through the repair.

## Changes Applied

Both Macs now have the following power policy:

- system, disk, display, standby, and automatic power-off sleep disabled;
- Wake-on-LAN and TCP keepalive enabled where the OS exposes them;
- standard macOS restart-after-freeze and restart-after-power-failure enabled.

Both Macs keep automatic checks, critical system files, and security-data
updates enabled. Automatic macOS downloads and automatic macOS installation
are disabled. A major release now requires an explicit user action.

The latest per-user interactive stability guard is live on the 7050 and runs
every two minutes:

- applies nice level 19 plus macOS background, throughput tier 5, and latency
  tier 5 scheduling policy to `bird`, `fileproviderd`, `mediaanalysisd`,
  `photoanalysisd`, `cloudphotod`, and `photolibraryd`;
- records free space, WindowServer, VNC, UU process count, and the busiest
  covered background worker;
- warns below 25 GiB free;
- records UU process presence but leaves startup and repair to the dedicated
  unattended supervisor;
- rotates its own log at 1 MiB.

This does not disable iCloud or Photos analysis. It lets those services
finish with lower scheduling priority so WindowServer and remote input remain
responsive.

On 2026-07-30 the 3040 returned and the current guard revision was installed.
The dedicated UU supervisor was also verified healthy with its root daemon,
Aqua agent, server process, 30-second watchdog, and fresh heartbeat present.
No TCC database, Apple ID state, iCloud database, Photos library, UU account,
boot argument, device property, or kext was modified by the stability work.

The live controls reduce software contention; they do not remove the 7050's
hardware-port loop or create disk space. The remaining maintenance priorities
are to disable or repair optical `SATA-1`, keep at least 25 GiB free, and
activate the reviewed TRIM candidate only during a planned restart.

## 2026-07-30 3040 Follow-up

The successful Monterey boot was observed from its first minutes rather than
after the desktop had settled. `mds_stores` briefly consumed about 457 percent
CPU while Spotlight opened the newly attached APFS data volumes. It fell to
about 1 percent within three minutes. Memory pressure was healthy, swap I/O
was zero, the Monterey container had about 89 GiB free, SMART was Verified,
and protected logs contained no panic, watchdog, GPU restart, memory, or live
storage error.

`Mac Data` and `Sequoia Data` are data/staging volumes on the slower 1 TB hard
disk and do not need interactive search indexing. Indexing was disabled on
both and each now carries `.metadata_never_index`. Monterey itself remains
indexed. This removes the reproducible login-time CPU burst without globally
disabling Spotlight.

```bash
sudo mdutil -i off "/Volumes/Mac Data"
sudo mdutil -i off "/Volumes/Sequoia Data"
sudo touch "/Volumes/Mac Data/.metadata_never_index"
sudo touch "/Volumes/Sequoia Data/.metadata_never_index"
mdutil -s "/Volumes/Mac Data" "/Volumes/Sequoia Data"
```

The power and update policy was reapplied and verified:

- sleep, disk sleep, display sleep, standby, power nap, and automatic
  power-off are disabled;
- Wake-on-LAN, TCP keepalive, restart after freeze, and restart after power
  failure are enabled;
- major macOS download and installation remain manual;
- critical and configuration-data updates remain enabled.

A later controlled `shutdown -r now` completed shutdown but the host did not
return to ARP, ping, or SSH during the bounded observation window. Do not call
that a desktop freeze: the remote evidence cannot distinguish a machine that
powered off instead of restarting from a stop at firmware, OpenCore, Apple
boot, or loginwindow. The physical power LED and display stage are required
before another reset. Once it returns, inspect the immediately preceding
shutdown/OpenCore logs before changing kexts or power policy again.

## 3040 HD 530 Framebuffer Evidence

The later flashing report produced a narrower hardware-path finding:

- the CPU and physical iGPU are Skylake (`i7-6700`, HD 530 device `0x1912`);
- the live Monterey config injects Kaby Lake device `0x5912`, platform
  `00001259`, and boot argument `-igfxsklaskbl`;
- Monterey consequently loads `AppleIntelKBLGraphics` and
  `AppleIntelKBLGraphicsFramebuffer`;
- protected kernel logs contain recurring `TxnHang1`, `TxnHang2`, fake-VBL,
  skipped-flip, and gamma/flip events during UU/VNC display changes and
  GPU-enabled Codex launches;
- there was no corresponding kernel panic, WindowServer crash, swap pressure,
  SMART failure, or live storage I/O error.

This makes the framebuffer path the leading freeze/flashing cause. Codex is a
reproducible trigger, not proof that the signed Codex bundle is defective.
The original Codex app passed deep signature verification with identifier
`com.openai.codex` and OpenAI Team ID `2DC432GLL2`.

The upstream basis for a native Monterey candidate is explicit:

- [WhateverGreen's Intel FAQ](https://github.com/acidanthera/WhateverGreen/blob/master/Manual/FAQ.IntelHD.en.md)
  lists Skylake support through macOS 12 and reserves Skylake-to-Kaby
  spoofing for macOS 13 and later;
- [Dortania's desktop Skylake configuration](https://dortania.github.io/OpenCore-Install-Guide/config.plist/skylake.html)
  uses native desktop HD 530 platform `00001219` without a Kaby device-ID
  spoof.

The guarded candidate therefore changes only:

1. `AAPL,ig-platform-id`: `00001259` to `00001219`;
2. removal of injected `device-id=12590000`;
3. removal of `-igfxsklaskbl`.

It retains the reviewed framebuffer memory patches, OpenCore 1.0.7, SMBIOS,
kexts, ACPI, and every non-graphics setting. It is staged as a separate
`EFI/OC` tree on the Samsung Windows ESP. Both Microsoft loaders, BCD, the
live Mac EFI, partitions, and the saved picker default are hash-checked and
left unchanged.

```bash
./stage-optiplex-3040-monterey-native-graphics.sh audit \
  --source-device <MACRECOVERY-diskXsY> \
  --target-device <WIN10-EFI-diskXsY> \
  --ocvalidate /path/to/OpenCore-1.0.7/ocvalidate
```

Source:
[stage-optiplex-3040-monterey-native-graphics.sh](./scripts/stage-optiplex-3040-monterey-native-graphics.sh)

`bless --nextonly` was attempted only after backup and validation. This
firmware/OpenRuntime combination rejected the write with `0xe00002e2`; no
`efi-boot-next` variable appeared. Do not retry that command as if it worked.
The external-entry helper adds a clearly named, non-default OpenCore picker
item and can remove it transactionally:

```bash
./arm-optiplex-3040-monterey-native-picker.sh audit \
  --source-device <MACRECOVERY-diskXsY> \
  --target-device <WIN10-EFI-diskXsY> \
  --ocvalidate /path/to/OpenCore-1.0.7/ocvalidate
```

Source:
[arm-optiplex-3040-monterey-native-picker.sh](./scripts/arm-optiplex-3040-monterey-native-picker.sh)

The first automated firmware handoff to the candidate did not return to the
LAN within four minutes. At that point the candidate was **not promoted**.
The physical picker later returned and the operator selected the prior normal
`Monterey` entry. Monterey 12.7.6, key-only SSH, and UU all returned. The
candidate ESP contained no new `opencore-*.txt`, so there is no evidence that
the one-time firmware handoff reached the candidate OpenCore loader.

The candidate marker, loader, config, hashes, disk layout, current NVRAM, and
latest normal OpenCore log were preserved under ignored private storage. The
custom `Monterey Native Graphics Test` entry was then removed transactionally.
The live Mac ESP was remounted read-only and matching OpenCore 1.0.7
`ocvalidate` passed. The candidate remains staged but unaccepted; do not
re-arm it until firmware handoff is tested separately from the graphics
change.

The saved default resolves to Monterey's exact APFS Preboot volume group,
`ShowPicker` is enabled, and the timeout is five seconds. The picker also
showed `No Name`; this is a read-only 1.8 MB FAT12 virtual driver flash
exported by an attached `aicsemi` USB peripheral, not an operating system.
Leave it alone or unplug that peripheral instead of changing OpenCore scan
policy during stabilization.

```powershell
.\cleanup-optiplex-3040-native-test-boot.ps1 -Mode Audit
.\cleanup-optiplex-3040-native-test-boot.ps1 `
  -Mode Cleanup `
  -Confirm CLEANUP-3040-NATIVE-TEST
```

Source:
[cleanup-optiplex-3040-native-test-boot.ps1](./scripts/cleanup-optiplex-3040-native-test-boot.ps1)

The planned Windows 10 maintenance boot completed on 2026-07-30. `Audit`
matched the reviewed candidate ESP, marker, OpenCore hash, description, path,
and temporary firmware object before `Cleanup` was confirmed. The helper
exported the live BCD and firmware state, removed only that object, and a
second audit reported it absent. Windows Boot Manager, the normal Monterey
entry, persistent defaults, loaders, and partitions were unchanged.

That run also exposed a Windows API edge case: a drive letter assigned by
`mountvol /S` was not visible through `Get-Partition -DriveLetter`. The
helper now verifies the mounted ESP by comparing its stable volume-GUID path
with the reviewed partition access path. The corrected PowerShell 5.1 script
passed `Audit`, `Cleanup`, and the post-cleanup audit on the real machine.

The first mitigation experiment launched the untouched signed desktop app with
Electron `--disable-gpu`. The flags were applied: the main process showed
`--disable-gpu` and its graphics helper showed `--use-gl=disabled`. However,
the main process then consumed 86-100 percent of one CPU core continuously for
more than five minutes and macOS generated a `cpu_resource` diagnostic. The
process was stopped and that launcher was removed. Treat software-rendered
Codex desktop as **failed**, not as a stability fix.

The accepted fallback uses the already installed text-only Codex CLI:

```bash
./install-codex-cli-launcher-macos.sh install
```

Source:
[install-codex-cli-launcher-macos.sh](./scripts/install-codex-cli-launcher-macos.sh)

The helper requires `codex` under the user's nvm tree, verifies that the
matching global npm package is exactly `@openai/codex`, and creates an
executable `Codex CLI.command` plus Desktop shortcut. Its install path also
removes the rejected Electron launcher. On this host it verified
`codex-cli 0.146.0`; that version is an evidence snapshot, not a pin.

The recovery watch completed 20 ping/SSH checks over ten minutes without a
failure. WindowServer remained near idle, swap remained zero, and the
protected kernel-log delta contained no new framebuffer transaction hang,
fake VBL, skipped flip, GPU restart/panic, watchdog timeout, or storage I/O
error. The signed desktop app's CPU failure still makes the CLI the accepted
operating path.

Keep using the CLI until a graphics candidate passes physical display, UU,
VNC, SSH, and protected-log acceptance. Keep complete EFI/NVRAM backups
private and off-machine.

## Unattended UU Startup

UU Remote has two native launchd jobs: a root daemon loaded at boot and a
per-user agent loaded into the macOS GUI session. A controllable Aqua desktop
does not exist until a user session starts. On the 7050, `autoLoginUser` is
already `lachlan` and FileVault is off, so macOS can create that session
without a post-reboot keyboard action. The installer audits these facts but
never creates an auto-login password or changes FileVault.

Install the companion scripts from the same directory:

```bash
./install-macos-uuremote-unattended.sh audit
./install-macos-uuremote-unattended.sh \
  install UU-UNATTENDED-STARTUP
```

The root supervisor starts at boot and checks every 30 seconds. It:

- validates the signed UU app and expected Team ID before any repair;
- repairs a missing root daemon and enables the native jobs;
- waits through a 60-second boot grace, then repairs a missing Aqua agent
  after two consecutive checks;
- uses `uuyc-cli status`, not incidental cloud sockets, to verify login,
  network, and XPC health;
- waits through five unhealthy CLI checks and validates external connectivity
  before restarting a running agent;
- checks `uuyc-cli device status` and extra established sockets before acting,
  so an active remote session is left alone;
- removes only a stale root loginwindow agent after the real Aqua user appears;
- preserves UU credentials, device identity, TCC permissions, and both signed
  vendor plists;
- rotates its 2 MiB log and writes a credential-free heartbeat.

The 7050 installer migrated the earlier machine-specific watchdog into a
timestamped root-only backup. It did not restart the healthy UU processes.
The generic supervisor is the sole UU repair owner; the two-minute
interactive stability guard now only monitors UU.

Audit after an in-app UU update and after the next planned reboot:

```bash
./install-macos-uuremote-unattended.sh audit
sudo launchctl print system/com.lachlan.macos-uuremote-unattended
sudo cat /var/db/com.lachlan.macos-uuremote-unattended/heartbeat
sudo tail -n 50 /var/log/macos-uuremote-unattended.log
```

An installed supervisor is not a substitute for an Aqua session. If
`auto_login_user=disabled`, either log in locally after reboot or configure
auto-login through macOS System Settings after considering the physical
security tradeoff. Do not put a login password in these scripts.

## 7050 Storage Maintenance

The active 7050 OpenCore binary exactly matched official OpenCore 1.0.7, and
its config passed the matching `ocvalidate`. The config has
`Kernel -> Quirks -> ThirdPartyDrives=false`, and macOS reports `TRIM
Support: No` for the Micron 1100 SATA SSD. OpenCore's `ThirdPartyDrives`
quirk exists specifically to fix third-party SSD TRIM and SATA hibernation.

A full private EFI backup and a one-line candidate with
`ThirdPartyDrives=true` were created. The candidate passed OpenCore 1.0.7
`ocvalidate`; it is not live and no restart has occurred.

Use the guarded transition during a maintenance window:

```bash
./promote-optiplex-7050-trim-config.sh \
  audit ~/Downloads/ocvalidate-1.0.7

./promote-optiplex-7050-trim-config.sh \
  apply ~/Downloads/ocvalidate-1.0.7 \
  ENABLE-TRIM-OPTIPLEX-7050
```

The promoter accepts only the reviewed Micron geometry, exact official
OpenCore and `ocvalidate` hashes, and either the known current or one-line
candidate config hash. It backs up the live config, restores it on a failed
validation, and never restarts the Mac. After a planned restart, verify:

```bash
system_profiler SPSerialATADataType |
  grep -A18 'Micron 1100 SATA 512GB'
```

`TRIM Support` must be `Yes`.

The optical-drive fault requires a firmware or hardware action. At the next
maintenance restart:

1. enter Dell setup with `F2`;
2. open **System Configuration -> Drives**;
3. disable only `SATA-1`, which is the reviewed optical-drive port;
4. leave `SATA-0` and AHCI operation enabled;
5. run Dell ePSA storage diagnostics once;
6. boot macOS and verify a ten-second kernel stream has no command aborts:

```bash
sudo log stream \
  --style compact \
  --timeout 10 \
  --predicate \
  'process == "kernel" AND eventMessage CONTAINS[c] "AbortCommands"'
```

If the optical drive is needed, power the computer off and reseat or replace
its SATA/power connection instead of disabling the port. Dell documents the
drive cable as a removable service part. Do not disable SATA operation or
SATA-0; that would also hide the system SSD.

## Install and Audit

Copy these scripts to the Mac and run them as the logged-in desktop user:

```bash
./configure-macos-stability-policy.sh audit
./configure-macos-stability-policy.sh \
  apply MACOS-STABILITY-POLICY
./install-macos-interactive-stability-guard.sh install
./install-macos-interactive-stability-guard.sh audit
./install-macos-uuremote-unattended.sh audit
```

The policy script requests administrator authentication once in `apply`
mode. It uses same-filesystem update accounting, reports staged update data,
and never deletes it.

Run the bounded evidence collector without privilege for a normal check:

```bash
./audit-macos-remote-stability.sh 12
```

Run it with `sudo` only when protected shutdown and watchdog log evidence is
needed:

```bash
sudo ./audit-macos-remote-stability.sh 12
```

The UU process streams are intentionally excluded from the unified-log query.
Querying every UU message made `log show` scan for an unbounded amount of
time; diagnostic resource reports and current process state provide the
needed UU evidence. The protected historical kernel query has a 20-second
safety limit, and a separate five-second live sample detects active storage
command errors without flooding the report. The audit deliberately does not
run a full Serial-ATA `system_profiler` scan; polling the known-faulty optical
port is unnecessary during routine health checks.

The collector also reports the active Intel Skylake/Kaby graphics
extensions, injected platform/device properties, boot arguments, and bounded
`TxnHang`/fake-VBL/skipped-flip evidence. This distinction matters because a
framebuffer transaction hang can cause flashing or a remote-desktop stall
without producing a conventional GPU restart or panic report.

The guard is reversible:

```bash
./install-macos-interactive-stability-guard.sh uninstall
```

Logs are at:

```text
~/Library/Logs/MacInteractiveStabilityGuard.log
~/Library/Logs/MacInteractiveStabilityGuard.log.previous
```

## 3040 Boot Default

The 3040's persistent OpenCore NVRAM target was verified to resolve to the
`Monterey` APFS volume group and its Preboot `boot.efi`. There was no
`recovery-boot-mode` or `efi-boot-next` override.

The live OpenCore configuration on `MACRECOVERY` was also verified:

| Setting | Value |
| --- | --- |
| `ShowPicker` | `true` |
| `Timeout` | `5` |
| `AllowSetDefault` | `true` |
| `PickerMode` | `External` |

The persistent default is therefore Monterey, not macOS Recovery. Do not
select Recovery with the set-default modifier. If NVRAM is reset, select
Monterey and press `Ctrl+Enter`; on firmware that does not report Ctrl, hold
`+` while pressing Enter.

## Post-change Checks

```bash
ssh -o BatchMode=yes optiplex-3040-macos \
  'launchctl print gui/$(id -u)/com.lachlan.macos-interactive-stability-guard'

ssh -o BatchMode=yes glassagent-mac \
  'launchctl print gui/$(id -u)/com.lachlan.macos-interactive-stability-guard'

nc -vz 192.168.1.209 22
nc -vz 192.168.1.209 5900
nc -vz 192.168.1.99 22
nc -vz 192.168.1.99 5900
```

For a new failure, first test ping, SSH, and VNC. A router or route outage can
make both Macs appear down at once. If SSH works, capture the audit and top
processes before restarting anything. If the host restarted, preserve the
panic and diagnostic reports before changing EFI.

When the 3040 returns, capture `last reboot shutdown`, the protected audit,
and its SATA error sample before applying or updating the guard. This is
necessary to distinguish the current outage from the earlier UU wakeup
reports.

Wake-on-LAN can recover a powered-off machine. It cannot repair an awake
kernel hard lock, so repeated wake packets are not a substitute for crash
evidence.

## Compatibility Layer Review

The loaded versions on both Macs matched the latest Acidanthera releases
checked on 2026-07-28:

| Component | Loaded version |
| --- | --- |
| Lilu | 1.7.2 |
| WhateverGreen | 1.7.0 |
| AppleALC | 1.9.7 |
| RestrictEvents | 1.1.6 |
| IntelMausi, 7050 | 1.0.8 |

Do not update a working EFI simply because the remote desktop is busy. Update
OpenCore and all interdependent kexts together only after a backup, an
`ocvalidate` pass against the matching release, and a boot test on removable
media.

## References

- [Apple: free storage space on Mac](https://support.apple.com/en-us/102624)
- [Apple: if a Mac runs slowly](https://support.apple.com/guide/mac-help/if-your-mac-runs-slowly-mchlp1731/mac)
- [Apple: background security improvements](https://support.apple.com/en-us/101591)
- [Apple: Software Update settings](https://support.apple.com/en-au/guide/mac-help/mchla7037245/mac)
- [OpenCore configuration reference](https://dortania.github.io/docs/latest/Configuration.html)
- [Acidanthera OpenCore releases](https://github.com/acidanthera/OpenCorePkg/releases)
- [Acidanthera Lilu releases](https://github.com/acidanthera/Lilu/releases)
- [Acidanthera WhateverGreen releases](https://github.com/acidanthera/WhateverGreen/releases)
- [Acidanthera AppleALC releases](https://github.com/acidanthera/AppleALC/releases)
- [Acidanthera RestrictEvents releases](https://github.com/acidanthera/RestrictEvents/releases)
- [Acidanthera IntelMausi releases](https://github.com/acidanthera/IntelMausi/releases)
- [OpenCore changelog: ThirdPartyDrives](https://github.com/acidanthera/OpenCorePkg/blob/master/Changelog.md)
- [Dell OptiPlex 7050 drive controls](https://www.dell.com/support/manuals/en-ca/optiplex-7050-sff/optiplex-7050-desktop-sff-om/system-setup-options)
- [Dell OptiPlex 7050 optical-drive service procedure](https://www.dell.com/support/manuals/en-us/optiplex-7050-sff/optiplex-7050-desktop-sff-om/optical-drive)
