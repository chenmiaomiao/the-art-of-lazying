# OptiPlex 3040 and 7050 macOS Stability

This runbook records the 2026-07-28 investigation of intermittent remote
desktop stalls on the OptiPlex 3040 Monterey and OptiPlex 7050 Sequoia
Hackintoshes. It separates a real macOS crash from an alive but overloaded
desktop before changing OpenCore.

## Conclusion

Neither Mac had evidence of a kernel, graphics, power, or memory crash.
The 7050 remained responsive after the controls below were installed: SSH,
VNC, WindowServer, and all expected UU processes stayed up while the covered
iCloud and Photos workers settled to zero or near-zero CPU.

| Evidence | OptiPlex 3040 | OptiPlex 7050 |
| --- | --- | --- |
| Last shutdown cause | Software initiated | Software initiated |
| Panic, watchdog, GPU restart, or WindowServer report | None found | None found |
| Intel HD 530 acceleration and active display | Healthy | Healthy |
| Memory pressure, compression, and swap | Healthy | Healthy |
| SMART status | Verified | Verified |
| Sleep/wake cycles | None | None |
| APFS free space | About 89 GiB | About 15 GiB |
| SATA command errors | None found | Continuous on optical-drive port 1 |
| Persistent background load | None | iCloud Drive and Photos analysis |
| UU Remote resource reports | Excessive wakeups | Excessive wakeups |

The 3040 was healthy after its software restart. Its only recurring anomaly
was UU Remote exceeding macOS's wakeup-rate threshold. Two reports measured
45,001 wakeups in 196 and 50 seconds, or approximately 230 and 908 wakeups per
second. macOS recorded the reports but took no action.

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
- leaves an active UU session untouched;
- restarts the signed UU user LaunchAgent only after its processes are absent
  for three consecutive checks;
- rotates its own log at 1 MiB.

This does not disable iCloud or Photos analysis. It lets those services
finish with lower scheduling priority so WindowServer and remote input remain
responsive.

The 3040 had the earlier reversible guard installed, but became unreachable
before this final nice-level-19 revision could be deployed. Install the
repository version after collecting its next-boot evidence. No TCC database,
Apple ID state, iCloud database, Photos library, UU account, EFI file, boot
argument, device property, or kext was modified.

The live controls reduce software contention; they do not remove the 7050's
hardware-port loop or create disk space. The remaining maintenance priorities
are to disable or repair optical `SATA-1`, keep at least 25 GiB free, and
activate the reviewed TRIM candidate only during a planned restart.

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
