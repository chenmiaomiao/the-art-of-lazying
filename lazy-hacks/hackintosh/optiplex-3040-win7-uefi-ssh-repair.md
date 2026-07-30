# OptiPlex 3040 Windows 7 UEFI and SSH Repair

Status date: 2026-07-30

Status: the Windows 7 SP1 installation booted successfully through a
one-time Windows Boot Manager validation path. Its OpenSSH 8.9.1 service
started automatically, accepted the dedicated Ed25519 key, exposed no
password authentication, and logged the accepted session. The host then
returned to the unchanged Monterey 12.7.6 installation.

The complete test was repeated from Monterey on the same date without
physical console interaction. It passed an offline Win10 verification, a
staged high-port SSH smoke test, the real Win7 boot and live SSH gates, a
transactional cleanup pass, and the final Monterey return gate. UU Remote
remained available but was not needed.

The operator separately reports that OpenCore's direct Windows 7 picker entry
is bootable. The reproducible evidence in this guide specifically validates
the disposable Windows Boot Manager path and its SSH acceptance gates. Keep
those results distinct until a direct-picker boot is captured with the same
host-key, service, firewall, and log checks.

## Security Boundary

Windows 7 is unsupported and must not be treated as an Internet-facing host.
This repair deliberately:

- permits SSH only from `LocalSubnet`;
- enables public-key authentication only;
- disables SSH password and challenge-response authentication;
- does not change any Windows account password;
- does not expose TCP 22 through the router;
- pins one Microsoft-signed Win32-OpenSSH release and verifies its SHA-256;
- keeps complete offline rollback data before changing Win7;
- leaves Win10, Monterey, partition tables, and persistent defaults intact.

Keep private keys, host keys, raw registry hives, BCD stores, disk GUIDs,
complete EFI trees, IP/MAC addresses, and passwords outside Git.

## Incident

The 1 TB Windows 7 disk had been converted from an older MBR layout to pure
GPT. The files survived, including:

- 64-bit Windows 7 SP1 build `6.1.7601`;
- `\Windows\System32\winload.efi`;
- `\EFI\Boot\bootx64.efi`;
- `\EFI\Microsoft\Boot\bootmgfw.efi`;
- `\EFI\Microsoft\Boot\BCD`.

The UEFI BCD no longer resolved the converted partition. Before repair, its
active objects contained:

```text
Windows Boot Manager device: unknown
Windows Boot Loader device:  unknown
Windows Boot Loader osdevice: unknown
```

OpenCore could discover the NTFS loader through `OpenNtfsDxe`, but Windows
Boot Manager could not locate the operating system. This was a BCD
partition-identity problem, not a missing Win7 installation.

An earlier OpenSSH preview was also present but had failed configuration
validation. Its installation helper depended on permission behavior that had
not completed correctly on the old system.

## Tested Tools

- Windows 10 PowerShell 5.1 as the stable administrative control plane;
- `Get-Disk`, `Get-Partition`, `Get-Volume`, CIM, and file-version APIs;
- `bcdedit` with an explicit offline store;
- `reg load`/`reg unload` for offline SYSTEM and SOFTWARE hives;
- `robocopy`, `Get-FileHash`, and SHA-256 manifests;
- `Get-AuthenticodeSignature`;
- SID-based `icacls`;
- `sc.exe`, `netsh advfirewall`, `netstat`, and OpenSSH logs;
- a short-lived SYSTEM scheduled task for a high-port daemon smoke test;
- dedicated SSH aliases and host-key files on the Ubuntu controller;
- matching OpenCore 1.0.7 `ocvalidate` for every temporary picker edit.

The OpenSSH source was the official
[PowerShell/Win32-OpenSSH 8.9.1.0p1 release](https://github.com/PowerShell/Win32-OpenSSH/releases/tag/v8.9.1.0p1-Beta).
The project documents GitHub release support for
[Windows 7 and newer](https://github.com/PowerShell/Win32-OpenSSH/wiki/Install-Win32-OpenSSH).

Pinned archive:

```text
OpenSSH-Win64.zip
SHA-256 B3D31939ACB93C34236F420A6F1396E7CF2EEAD7069EF67742857A5A0BEFB9FC
sshd.exe 8.9.1.0 / OpenSSH_8.9p1 for Windows
```

`sshd.exe`, `ssh.exe`, `ssh-keygen.exe`, and `sftp-server.exe` all passed
Microsoft Authenticode validation on the controlling Win10 installation.

## Scripts

### Offline repair

[`repair-optiplex-3040-win7-offline.ps1`](./scripts/repair-optiplex-3040-win7-offline.ps1)
has four modes:

- `Audit`: validates the machine, disk, Win7 build, BCD shape, package hash,
  signatures, public key, and backup volume without changing Win7.
- `Apply`: saves rollback evidence, repairs only the isolated Win7 UEFI BCD,
  installs SSH, writes offline service/firewall state, and verifies it.
- `Verify`: independently checks the active BCD objects, signatures, config,
  key, ACL-sensitive daemon parse, service registry, and firewall registry.
- `Rollback`: restores the saved Win7 EFI, prior SSH trees, registry hives,
  and root picker label while Win7 remains offline.

The helper is intentionally machine-specific. It checks the Dell model,
Toshiba disk model and size, exact Win7 partition offset/size, NTFS label,
Win7 SP1 kernel build, required EFI files, user profile, and backup volume.
Pass the private partition GUID as an additional guard without putting it in
Git.

```powershell
$repair = ".\repair-optiplex-3040-win7-offline.ps1"
$zip = "$env:USERPROFILE\Downloads\OpenSSH-Win64-8.9.1.0p1.zip"
$key = "$env:USERPROFILE\Downloads\optiplex-3040-admin.pub"
$privateGuid = Get-Content "$env:USERPROFILE\Documents\private-win7-guid.txt"

& $repair -Mode Audit `
  -OpenSshZip $zip `
  -PublicKeyPath $key `
  -Win7User Dell `
  -BackupVolumeLabel "Data Fire" `
  -ExpectedWin7PartitionGuid $privateGuid

& $repair -Mode Apply `
  -OpenSshZip $zip `
  -PublicKeyPath $key `
  -Win7User Dell `
  -BackupVolumeLabel "Data Fire" `
  -ExpectedWin7PartitionGuid $privateGuid

& $repair -Mode Verify `
  -PublicKeyPath $key `
  -Win7User Dell `
  -BackupVolumeLabel "Data Fire" `
  -ExpectedWin7PartitionGuid $privateGuid
```

The successful `Apply` prints its timestamped rollback directory. Keep that
exact path:

```powershell
& $repair -Mode Rollback `
  -RollbackStatePath "G:\SYSTEM-REPAIR\win7-uefi-ssh\<timestamp>" `
  -Win7User Dell `
  -BackupVolumeLabel "Data Fire" `
  -ExpectedWin7PartitionGuid $privateGuid
```

Never run `Rollback` from Win7 itself. The target EFI, SSH files, and registry
hives must be offline.

### High-port smoke test

[`smoke-optiplex-3040-win7-openssh.ps1`](./scripts/smoke-optiplex-3040-win7-openssh.ps1)
starts the staged Win7 daemon on Win10 as SYSTEM, using a temporary
local-subnet firewall rule and a nonstandard port. It does not stop or replace
Win10's normal SSH server. The scheduled task has a 15-minute execution limit.

```powershell
.\smoke-optiplex-3040-win7-openssh.ps1 `
  -Mode Start `
  -Win7DriveLetter D `
  -Port 2227
```

From the controller, use the dedicated Win7 private key and a separate
known-hosts file:

```bash
ssh -p 2227 \
  -i ~/.ssh/id_ed25519_optiplex_3040 \
  -o IdentitiesOnly=yes \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile=~/.ssh/known_hosts_optiplex_3040_win7_smoke \
  win10-control-user@3040-address \
  'echo STAGED_WIN7_SSHD_KEY_AUTH_OK && whoami && ver'
```

Always clean it immediately:

```powershell
.\smoke-optiplex-3040-win7-openssh.ps1 -Mode Stop -Port 2227
```

Acceptance requires successful key authentication, the staged binary path,
the intended high port, and confirmation that the task, process, listener,
and firewall rule are all absent after `Stop`.

### One-time real boot

[`arm-optiplex-3040-win7-one-time-test.ps1`](./scripts/arm-optiplex-3040-win7-one-time-test.ps1)
creates two disposable links:

1. firmware `bootsequence` to the existing Windows Boot Manager;
2. Windows Boot Manager `bootsequence` to a temporary Win7 OS-loader object.

It does not add the object to normal display order and does not change the
persistent firmware order, Win10 default, or Monterey default.

```powershell
$state = "G:\SYSTEM-REPAIR\win7-uefi-ssh\<successful-timestamp>"

.\arm-optiplex-3040-win7-one-time-test.ps1 `
  -Mode Audit `
  -RepairState $state `
  -Win7DriveLetter D

.\arm-optiplex-3040-win7-one-time-test.ps1 `
  -Mode Arm `
  -RepairState $state `
  -Win7DriveLetter D
```

Read back all three objects before reboot:

```powershell
bcdedit /enum "{fwbootmgr}" /v
bcdedit /enum "{bootmgr}" /v
bcdedit /enum "<temporary-loader-id>" /v
```

Required pre-reboot facts:

- firmware `bootsequence` is Windows Boot Manager;
- Windows Boot Manager `bootsequence` is the new temporary loader;
- temporary `device` and `osdevice` resolve to the Win7 partition;
- path is `\Windows\System32\winload.efi`;
- normal `displayorder` and `default` values are unchanged.

The script does not reboot. Reboot only after the controller has started
bounded polling for the dedicated Win7 SSH alias.

## What Apply Changes

### Isolated Win7 BCD

Only `\EFI\Microsoft\Boot\BCD` on the Win7 NTFS partition is repaired:

- boot manager device becomes the Win7 GPT partition;
- OS loader device and osdevice become that partition;
- OS loader remains `winload.efi`;
- stale resume references are removed from the two active objects;
- normal description becomes `Windows 7`;
- timeout becomes eight seconds;
- root and loader-adjacent `.contentDetails` files become `Windows 7`.

Dormant memory-test and resume objects may still print `unknown`. They are not
the active boot manager or active OS loader and must not make validation fail.
Do not delete unrelated BCD objects merely to make an audit cosmetically
empty.

The legacy root `\Boot\BCD` is backed up but not rewritten. Pure GPT no longer
provides the old BIOS/active-MBR handoff, so pretending that path is repaired
would be misleading.

### Offline OpenSSH

The script:

1. backs up prior `Program Files\OpenSSH` and `ProgramData\ssh`;
2. installs the pinned signed release;
3. preserves and validates existing Ed25519 and RSA host keys;
4. writes the supplied public key to
   `C:\ProgramData\ssh\administrators_authorized_keys`;
5. writes a minimal public-key-only `sshd_config`;
6. applies ACLs by well-known SID, independent of Windows display language;
7. validates the offline config with the staged daemon;
8. writes the automatic `sshd` service to current, default, and
   last-known-good offline control sets;
9. writes a TCP 22 `LocalSubnet` rule to each corresponding firewall store;
10. sets `cmd.exe` as the predictable default remote shell.

The installed config disables forwarding and limits sessions because this is
a recovery/control endpoint, not a general bastion.

A manual UU fallback command is stored at:

```text
C:\ProgramData\Win7OfflineRepair\repair-sshd-as-admin.cmd
```

Use it only if Win7 visibly reaches the desktop but TCP 22 does not start.
Run it as Administrator through the already consented UU session, inspect its
log, and return to SSH. UU is a fallback, not the primary debug path.

## Live Acceptance

Do not call the repair successful merely because Win7 appears on a display.
All of these gates passed on the reviewed machine:

```bash
ssh -o BatchMode=yes optiplex-3040-win7 \
  'echo WIN7_KEY_ONLY_SSH_OK && whoami && ver'
```

Observed properties:

- Windows version `6.1.7601`;
- local Win7 account;
- `sshd` service `AUTO_START`;
- service account `LocalSystem`;
- expected `C:\Program Files\OpenSSH\sshd.exe` binary path;
- service state `RUNNING`;
- daemon PID listening on `0.0.0.0:22`;
- firewall remote scope `LocalSubnet`;
- remote protocol `OpenSSH_for_Windows_8.9`;
- server offered only `publickey`;
- log recorded the expected Ed25519 fingerprint and accepted session.

Probe the disabled password path without sending a password:

```bash
ssh -vv \
  -o BatchMode=yes \
  -o IdentitiesOnly=yes \
  -o IdentityFile=/dev/null \
  -o PubkeyAuthentication=no \
  -o PreferredAuthentications=password \
  optiplex-3040-win7 true
```

The server must report:

```text
Authentications that can continue: publickey
Permission denied (publickey)
```

After the accepted session, verify both one-time `bootsequence` values have
been consumed. Delete the temporary loader recorded in
`one-time-win7-test.json`; `/cleanup` may also remove the resume object Win7
created during that boot. Confirm neither identifier nor description remains
in `bcdedit /enum all /v`. Running the helper's `Clear` mode from Win10 also
archives the test-state JSON with a `cleared` timestamp so a future validation
cycle cannot accidentally reuse an old loader identifier.

## Returning to Monterey

Reboot Win7 normally after the one-time objects are consumed. The persistent
firmware/OpenCore order should return to Monterey. Acceptance requires:

- macOS 12.7.6 identity over the dedicated macOS SSH alias;
- normal OpenCore config, not a candidate;
- `ScanPolicy=0`;
- `ShowPicker=true`;
- `UEFI/APFS/EnableJumpstart=true`;
- picker timeout five seconds;
- matching OpenCore 1.0.7 `ocvalidate`;
- live EFI remounted read-only.

The reviewed machine passed this return gate.

## Automated Mac-to-Win10 Handoff

macOS `bless --nextonly` and persistent `bless --setBoot` both failed with
`0xe00002e2` on this OpenRuntime/firmware combination. No boot variable was
written. Do not retry them as if they worked.

For unattended entry into Win10, the reviewed recovery used a temporary,
validated OpenCore config that permitted only internal SATA EFI-system
partitions:

```text
ScanPolicy = 0x10403
UEFI/APFS/EnableJumpstart = false
ShowPicker = false
Timeout = 2
```

The flags are:

- filesystem lock;
- device lock;
- EFI System Partition;
- SATA device.

This made the Win10 ESP the only primary target. The exact normal config and
temporary candidate were stored together on the live ESP, and off-machine
hashes were saved first. As soon as key-only Win10 SSH returned, Win10 copied
the exact rollback config over `EFI\OC\config.plist` and verified matching
SHA-256. Temporary transaction files were archived off-machine and later
removed from the live EFI.

This route is a recovery technique, not a normal setting. Leaving APFS
jumpstart disabled would hide Monterey. Always restore the normal config
before doing Windows repair work.

## Repeatable One-Time Retest from Monterey

The second acceptance cycle used this control flow:

```text
Monterey SSH
  -> temporary OpenCore selector
  -> Win10 SSH
  -> restore normal OpenCore immediately
  -> verify offline Win7
  -> stage and remove a high-port Win7 sshd smoke test
  -> arm disposable firmware and Windows boot sequences
  -> real Win7 key-only SSH
  -> normal reboot to persistent Monterey
  -> short Win10 cleanup pass
  -> final persistent Monterey
```

The normal Monterey config remained the persistent baseline throughout.
Only the two `bootsequence` values were used for Win7, and both are consumed
automatically after one boot. UU is reserved for identifying a failed screen
and rebooting to a known-good system when bounded SSH polling fails. It is not
the primary repair channel.

### 1. Discover the live EFI each boot

Do not hard-code a macOS disk identifier. The same `MACRECOVERY` partition
appeared under different `diskXsY` names across consecutive boots because
synthesized APFS container numbering changed.

```bash
diskutil list
diskutil info <MACRECOVERY-device>
sudo diskutil mount readOnly <MACRECOVERY-device>
mount | grep /Volumes/MACRECOVERY
```

Before writing, require all reviewed identity facts:

- volume name `MACRECOVERY`;
- partition type `EFI`;
- internal SATA parent disk;
- expected size;
- private partition UUID match;
- existing normal `EFI/OC/config.plist`;
- read-only mount for inspection.

Keep the UUID and complete EFI tree in private evidence, not Git. A mistaken
`disk3s6` assumption during the second cycle resolved to the mounted macOS
`Update` volume rather than `MACRECOVERY`. It was read-only and no write was
attempted. Re-discovery identified the correct EFI partition before work
continued.

### 2. Build a bounded Mac-to-Win10 transaction

Copy the *current* live config off-machine. Do not reuse an old rollback
blindly: an older reviewed copy had a 30-second picker timeout, while the
current normal config used five seconds.

Parse both property lists structurally. The temporary selector must differ
from the current normal config in exactly these four values:

```text
Misc/Boot/ShowPicker         true  -> false
Misc/Boot/Timeout               5  -> 2
Misc/Security/ScanPolicy        0  -> 66563 (0x10403)
UEFI/APFS/EnableJumpstart    true  -> false
```

Run the OpenCore 1.0.7 `ocvalidate` binary against both files. Store the exact
current config and candidate beside the live file, record their SHA-256
values off-machine, copy the candidate over `config.plist`, synchronize, and
remount the EFI read-only.

Spotlight's `mdsync` process may briefly hold the FAT volume open. If a normal
unmount is denied:

1. confirm the candidate and rollback hashes first;
2. run `sync`;
3. disable indexing only for the reviewed EFI mount;
4. force-unmount only that validated EFI device;
5. mount it read-only again;
6. rerun hash and `ocvalidate` checks.

Never force-unmount a device identified only by a stale `diskXsY` name.

After reboot, bounded polling must identify the Win10-specific SSH host key.
The first Win10 action is to copy the exact rollback over the active config
and verify its hash. Restore Monterey before inspecting or arming Win7.

### 3. Reverify Win7 from Win10

Parse the public helpers with the actual Windows PowerShell 5.1 parser, then
run the offline verifier:

```powershell
.\repair-optiplex-3040-win7-offline.ps1 `
  -Mode Verify `
  -PublicKeyPath "$env:USERPROFILE\Downloads\optiplex-3040-admin.pub" `
  -Win7User Dell
```

The verifier must confirm:

- exact reviewed machine, GPT disk geometry, Win7 volume, and SP1 build;
- active isolated BCD manager and loader bound to the Win7 partition;
- signed pinned OpenSSH binaries;
- valid public-key-only daemon configuration;
- automatic service state in current, default, and last-known-good control
  sets;
- TCP 22 `LocalSubnet` firewall state.

Run a fresh high-port smoke test before the real boot:

```powershell
.\smoke-optiplex-3040-win7-openssh.ps1 `
  -Mode Start `
  -Win7DriveLetter D `
  -Port 2227
```

Authenticate from the controller with the dedicated Win7 key. Acceptance
requires the staged binary on the Win7 volume, a SYSTEM process, the expected
port, and a local-subnet firewall rule. Always remove it:

```powershell
.\smoke-optiplex-3040-win7-openssh.ps1 -Mode Stop -Port 2227
.\smoke-optiplex-3040-win7-openssh.ps1 -Mode Status -Port 2227
```

`Status` must report no task, process, listener, or firewall rule.

### 4. Arm one real Win7 boot

Run `Audit` before `Arm`:

```powershell
$state = "G:\SYSTEM-REPAIR\win7-uefi-ssh\<successful-timestamp>"

.\arm-optiplex-3040-win7-one-time-test.ps1 `
  -Mode Audit `
  -RepairState $state `
  -Win7DriveLetter D

.\arm-optiplex-3040-win7-one-time-test.ps1 `
  -Mode Arm `
  -RepairState $state `
  -Win7DriveLetter D
```

Read back firmware manager, Windows manager, and the generated temporary
loader. Require:

- firmware one-time target is the existing Windows Boot Manager;
- Windows one-time target is the generated Win7 loader;
- loader `device` and `osdevice` resolve to the Win7 drive;
- loader path is `\Windows\System32\winload.efi`;
- persistent firmware display order is unchanged;
- Win10 remains the persistent Windows default;
- no reboot was requested by the helper.

Start bounded polling before reboot. Use the dedicated alias so host-key
separation prevents Win10 or macOS on the same address from producing a
false success:

```bash
ssh -o BatchMode=yes optiplex-3040-win7 \
  'echo WIN7_KEY_ONLY_SSH_OK && whoami && ver'
```

### 5. Apply live Win7 acceptance gates

The repeated cycle reached Windows `6.1.7601` and passed:

- `sshd` service start type `AUTO_START`;
- service account `LocalSystem`;
- expected signed binary path;
- service state `RUNNING`;
- service PID listening on `0.0.0.0:22`;
- live firewall registry value with `LPort=22` and `RA4=LocalSubnet`;
- server protocol `OpenSSH_for_Windows_8.9`;
- only `publickey` offered when password authentication was probed;
- accepted Ed25519 fingerprint recorded in `sshd.log`.

On Win7, query the firewall value directly by registry value name:

```cmd
reg query "HKLM\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules" /v OpenSSH-Server-In-TCP-Win7-KeyOnly
```

The localized `netsh` display name is not the registry value name, so a
display-name lookup can incorrectly print that no matching rule exists.

Windows 7's PowerShell version also lacks `Get-Content -Tail`. Use:

```powershell
Get-Content C:\ProgramData\ssh\logs\sshd.log |
  Select-Object -Last 25
```

Before leaving Win7, `bcdedit` should show that both one-time
`bootsequence` values were consumed. Reboot normally; the unchanged
persistent firmware order should return to Monterey.

### 6. Clean disposable state

The consumed temporary loader still needs explicit deletion. From Monterey,
use the same bounded selector for one short Win10 maintenance pass. Restore
the normal OpenCore config as the first Win10 action, then run:

```powershell
.\arm-optiplex-3040-win7-one-time-test.ps1 `
  -Mode Audit `
  -RepairState $state `
  -Win7DriveLetter D

.\arm-optiplex-3040-win7-one-time-test.ps1 `
  -Mode Clear `
  -RepairState $state `
  -Win7DriveLetter D

.\arm-optiplex-3040-win7-one-time-test.ps1 `
  -Mode Audit `
  -RepairState $state `
  -Win7DriveLetter D
```

Final Win10 acceptance requires:

- no firmware or Windows `bootsequence`;
- no generated loader identifier or test description in
  `bcdedit /enum all /v`;
- test JSON moved to a timestamped `one-time-win7-test-cleared-*.json`;
- normal OpenCore SHA-256 restored;
- temporary selector and rollback files removed from the live EFI;
- complete BCD and SSH evidence copied to ignored private storage.

Reboot normally and finish on Monterey. Verify macOS 12.7.6, the normal
five-second picker, unrestricted normal scan policy, APFS jumpstart,
matching OpenCore 1.0.7 validation, and a read-only EFI mount. Delete any
user-home candidate copy after the off-machine evidence is confirmed.

### UU fallback boundary

No UU action was needed during the repeated cycle. If bounded SSH polling
fails:

1. stop making boot changes;
2. use UU only to identify which known system or error screen is visible;
3. reboot to the known-good Monterey or Win10 control plane;
4. restore the normal OpenCore config before another attempt;
5. use the prepared Win7 administrative fallback only when Win7 visibly
   reaches its desktop but TCP 22 does not start.

Do not use UU to bypass authentication, modify account databases, or promote
an unverified boot candidate. Do not alter persistent defaults merely to
recover from a failed one-time test.

## Failures That Improved the Script

### PowerShell 5.1 compatibility

The first draft used an invalid one-argument `ASCIIEncoding` constructor and
attempted to recreate the existing `D:` drive root as a directory. The final
writer:

- creates a parent only when it does not already exist;
- uses the parameterless ASCII encoder;
- emits no BOM;
- allows `.contentDetails` to omit the final newline.

### ACL ordering

Recursively removing inheritance before granting the parent left copied
executables without effective child ACEs. The corrected order is:

1. set the directory owner;
2. put explicit SYSTEM/Administrators/Users ACEs on the parent;
3. reset children to inherit from that parent;
4. remove inheritance only on private host keys, config, and authorized keys;
5. grant those sensitive files only SYSTEM and Administrators.

Private host-key ACLs must be fixed before running `ssh-keygen -y`; otherwise
OpenSSH correctly rejects them as unprotected.

### Verification scope

The first verification rejected dormant BCD resume and memory-test objects
whose device remained `unknown`. The corrected verifier checks the active
boot manager and active OS loader separately while preserving the complete
store as evidence.

Each failed apply had a completed pre-change backup. The `Rollback` mode
restored EFI, SSH, and registry hashes before another attempt. No partial
failed state was reused.

## Direct Picker Evidence

The real Win7 OS, network stack, and SSH service are verified, and the
operator reports that the direct OpenCore entry boots. To give that route the
same independently recorded acceptance evidence:

1. stay at the machine with a physical display and keyboard;
2. boot the normal five-second OpenCore picker;
3. select the entry explicitly labelled `Windows 7`;
4. start bounded polling of `optiplex-3040-win7`;
5. accept only after the same key-only SSH and live-service gates pass;
6. reboot and confirm Monterey returns.

Do not temporarily exclude APFS to force this direct test while unattended.
That would remove the known-good remote fallback if the NTFS handoff failed.

The separate native-HD530 candidate remains unaccepted for the same reason:
its prior firmware handoff produced no candidate OpenCore log. Boot-path
evidence must be isolated before another graphics test. The working
Kaby-spoofed Monterey entry remains the recovery baseline.
