# OptiPlex 3040 Monterey and Multi-boot Operations

Status date: 2026-07-28

## Scope

This runbook starts after Monterey Setup Assistant has created the local
administrator. It covers key-only SSH, remote control in both directions,
development tools, readable volume and picker names, the graphical OpenCore
picker, a guarded NTFS-to-APFS data migration, and preparation-only Windows 11
and Sequoia staging.

The audited machine is a Dell OptiPlex 3040 with:

- Intel Core i7-6700 and HD Graphics 530;
- Realtek RTL8111 Ethernet;
- 8 GB DDR3L;
- a 256 GB Samsung GPT SSD containing Windows 10 and macOS;
- a 1 TB Toshiba GPT disk containing data, a legacy MBR Windows 7
  installation, and the dedicated `MACRECOVERY` ESP;
- a machine-specific OpenCore 1.0.7 EFI and 14-port USB map.

Do not use this record as an EFI for another 3040. The private EFI, generated
SMBIOS identity, GPT backups, and disk GUIDs belong in the separate
`hackintosh` repository's ignored private storage.

## Safety Boundary

The post-install script deliberately does not:

- edit OpenCore or firmware variables;
- rename an unidentified volume;
- enable automatic login;
- write a macOS TCC database;
- launch a macOS installer;
- execute a Windows upgrade tool;
- remove Monterey Recovery or either Windows installation.

Executing Tahoe, Sequoia, or Windows 11 upgrades is intentionally out of
scope. The preparation helpers may download and verify installers and create
an isolated empty target, but they never open an installer, change the startup
disk, or restart the computer. Keep the known-good Monterey installation until
the separate target, EFI candidate, rollback, and hardware acceptance tests
have all been reviewed.

Keep the physical display and keyboard connected for the first cold-boot test.
Make one boot-critical change at a time.

## Package Record

The reviewed UU Remote package is:

| Field | Value |
| --- | --- |
| Version | `4.33.0` |
| URL | `https://a56.gdl.netease.com/uuyc_4.33.0.pkg` |
| SHA-256 | `492ab1c360fb30f471dca71d2468be93d6a76a72b7d256d911f2095f72acefdd` |
| Installer signer | Hangzhou Bobo Technology Co Ltd |
| Team ID | `PU9BNSBJW7` |
| Notarization | trusted by Apple |

The package URL and digest match the Homebrew `uuremote` cask. The installer
script verifies the full SHA-256, Apple notarization result, installer Team
ID, and installed app Team ID before accepting it.

The development toolchain uses:

| Tool | Policy |
| --- | --- |
| nvm | pinned `0.40.4` archive and SHA-256 |
| Node.js | release line `22`, compatible with Intel Monterey |
| Codex CLI | current stable `@openai/codex` npm tag |

Node and Codex are installed under `~/.nvm`; do not use `sudo npm install -g`.

The additional reviewed desktop applications installed on Monterey are:

| App | Version | Signature |
| --- | --- | --- |
| Typora | `1.14.6` (`7780`) | Team ID `9HWK5273G4`; notarized |
| WeChat | `4.1.12` (`269340`) | Tencent Team ID `5A4RE8SF68`; notarized |

Both applications are universal binaries and declare Monterey-compatible
minimum system versions. On the Ubuntu workstation, the installed native
packages are Typora `1.13.6` and WeChat `4.1.1.8`.

## First Connection

Find the active address from the Mac:

```bash
ipconfig getifaddr en0
ipconfig getifaddr en1
```

Use a separate host-key namespace for each operating system because Windows
and macOS reuse the same NIC address and DHCP lease:

```sshconfig
Host optiplex-3040-macos
    HostName OptiPlex-3040-macOS.local
    HostKeyAlias optiplex-3040-macos
    User lachlan
    IdentityFile ~/.ssh/id_ed25519_optiplex_3040_macos
    IdentitiesOnly yes
    PasswordAuthentication no
    ServerAliveInterval 30
    ServerAliveCountMax 3

Host optiplex-3040-win10
    HostName 192.168.1.209
    HostKeyAlias optiplex-3040-win10
    User lachlan
    IdentityFile ~/.ssh/id_ed25519_optiplex_3040_win10
    IdentitiesOnly yes
```

Bootstrap the Mac key once with its local password, then disable password use
in the client alias only after key-only login passes:

```bash
ssh-copy-id \
  -i ~/.ssh/id_ed25519_optiplex_3040_macos.pub \
  lachlan@<mac-ip>

ssh -o BatchMode=yes optiplex-3040-macos true
```

The post-install script creates a separate outbound Mac key and an
`optiplex-7090-ubuntu` alias. Append the printed public key to the Ubuntu
account's `~/.ssh/authorized_keys`, then test from the Mac:

```bash
ssh -o BatchMode=yes optiplex-7090-ubuntu true
```

Never copy a private key between hosts.

## Post-install

Transfer the reviewed package, Ubuntu public key, and script to the Mac, then
run:

```bash
./postinstall-optiplex-3040-macos.sh \
  --uu-package ~/Downloads/uuyc_4.33.0.pkg \
  --authorized-key ~/Downloads/authorized_key.pub \
  --peer-host <ubuntu-ip> \
  --vnc-password
```

Source:
[postinstall-optiplex-3040-macos.sh](./scripts/postinstall-optiplex-3040-macos.sh)

The script:

- installs the Ubuntu public key and preserves existing authorized keys;
- creates a dedicated outbound Mac key;
- enables Remote Login and persistent `sshd`;
- assigns the unambiguous `OptiPlex-3040-macOS` Bonjour hostname;
- disables system, disk, standby, and display sleep;
- enables Wake-on-LAN, TCP keepalive, and automatic restart after power loss;
- enables Apple Remote Management for `lachlan`;
- optionally prompts without echo for a separate 1-8 character legacy VNC
  password;
- prevents unattended full macOS upgrades while keeping critical and
  configuration-data updates enabled;
- verifies and installs UU Remote, then restricts its per-user agent to the
  visible Aqua console;
- installs pinned nvm, Node 22, and the current stable Codex CLI.

## UU Remote Consent

Launch UU Remote locally once and grant only the permissions it requests in
System Settings:

1. Privacy & Security, Accessibility;
2. Privacy & Security, Screen Recording;
3. Local Network, if Monterey presents that control.

Do not edit `TCC.db`. The grants are tied to the stable signed bundle
`com.netease.uuremote` and Team ID `PU9BNSBJW7`. After granting them, quit and
reopen UU Remote and sign in to the intended account.

UU Remote also has two distinct software controls:

1. enable the app's account-device **Allow remote control** switch;
2. enable supported unattended assistance with
   `uuyc-cli assist allow on`.

Neither control grants Accessibility or Screen Recording by itself. Those two
macOS privacy grants still require local user consent.

Verify:

```bash
pgrep -fal '^/Applications/UURemote.app'
sudo launchctl print system/com.netease.uuremote.daemon
launchctl print "gui/$(id -u)/com.netease.uuremote.agent"
/Applications/UURemote.app/Contents/Helpers/uuyc-cli status
/Applications/UURemote.app/Contents/Helpers/uuyc-cli assist allow on
```

Test viewing, mouse input, ordinary phone-keyboard text, modifier keys, and
reconnection after logout separately.

The 2026-07-28 acceptance log recorded both privacy grants, synchronized the
local UU device as `controllable=true`, and accepted a mobile control
connection. Do not publish the account device ID or assistance code.

UU Remote 4.33.0 installs its per-user LaunchAgent for both `LoginWindow` and
`Aqua`. Apple Screen Sharing can create a temporary root loginwindow domain,
which previously launched a second UU agent and left mobile control spinning
on a login surface while Remmina showed the working desktop. The post-install
script backs up that signed vendor plist, changes only
`LimitLoadToSessionType` to `Aqua`, removes any root loginwindow instance, and
reloads one agent in the logged-in user's GUI domain. It does not alter TCC,
UU account state, or assistance credentials.

An in-app UU update may restore the vendor plist. Audit after each UU update:

```bash
./enforce-uuremote-aqua-session-macos.sh audit
```

Repair only when the audit reports `LoginWindow` or a root agent:

```bash
./enforce-uuremote-aqua-session-macos.sh apply UU-AQUA-ONLY
```

Source:
[enforce-uuremote-aqua-session-macos.sh](./scripts/enforce-uuremote-aqua-session-macos.sh)

## Apple Remote Desktop and VNC

The post-install script configures Apple's native Remote Management service
with observe and control privileges for `lachlan`. Monterey's bundled
`kickstart` can fail after activation while authorizing a specific user, so
the script verifies membership in the supported
`com.apple.access_screensharing` local group. With `--vnc-password`, it also
prompts without echo and enables Apple's legacy password-only VNC mode. No
password is embedded in the script or repository.

Verify locally:

```bash
sudo lsof -nP -iTCP:5900 -sTCP:LISTEN
sudo lsof -nP -iTCP:3283 -sTCP:LISTEN
```

Connect from a Mac with Screen Sharing:

```text
vnc://lachlan@OptiPlex-3040-macOS.local
```

On the Ubuntu workstation, install Remmina's VNC plugin and then create the
reusable launcher:

```bash
sudo apt install remmina remmina-plugin-vnc
./install-optiplex-3040-vnc-launcher-ubuntu.sh
```

Source:
[install-optiplex-3040-vnc-launcher-ubuntu.sh](./scripts/install-optiplex-3040-vnc-launcher-ubuntu.sh)

The installer prompts for the same legacy VNC password, stores only Remmina's
machine-local encrypted form in a mode-`600` profile, and keeps the public
script password-free. The accepted profile deliberately has:

- an empty username, which selects password-only VNC instead of Apple's
  incompatible account-authentication extension;
- legacy encryption disabled for this trusted-LAN connection;
- `scale=1`, `resolution_mode=2`, and a maximized window for auto-fit;
- clipboard and input enabled, with view-only mode disabled.

Do not run a second TigerVNC connection beside this profile. The tested
Remmina profile auto-fits and shares the visible Aqua desktop used by UU
Remote. The Aqua-only UU LaunchAgent prevents Apple's temporary VNC
loginwindow domain from receiving another UU agent.

For the other direction, the Microsoft Windows App releases after 11.2 no
longer support Monterey. Royal TSX 6 with its signed FreeRDP plugin is the
reviewed Monterey-compatible client. The launcher installer reads the RDP
password without echo, stores it in the macOS login Keychain, and creates
`OptiPlex 7090 - Current Desktop.app` on the Mac Desktop:

```bash
./install-optiplex-3040-rdp-launcher-macos.sh --password
```

Source:
[install-optiplex-3040-rdp-launcher-macos.sh](./scripts/install-optiplex-3040-rdp-launcher-macos.sh)

The launcher targets the Ubuntu physical GNOME session on TCP 3391. It does
not use GNOME's separate login-session service on TCP 3389, so connecting does
not displace work already open on the monitor.

Keep VNC and RDP limited to the trusted LAN; do not forward TCP 5900, 3389, or
3391 from the internet.

## Volume Naming

Audit before renaming:

```bash
diskutil apfs listVolumeGroups
diskutil info /
diskutil info /System/Volumes/Data
```

The accepted names are `Monterey` for the sealed System volume and
`Monterey - Data` for its paired Data volume. Rename only after the APFS volume
group and mount roles match:

```bash
sudo diskutil renameVolume / "Monterey"
sudo diskutil renameVolume /System/Volumes/Data "Monterey - Data"
```

Re-run the audit and confirm the System/Data volume group still has the same
container and volume UUIDs. Leave the dedicated `MACRECOVERY` label unchanged;
it identifies the rollback ESP.

APFS containers themselves do not have persistent user-facing labels.
Identifiers such as `disk1`, `disk2`, and `disk4` are assigned during device
discovery and can change after any restart. Name the volumes inside a container
instead. On this machine the audited labels are:

| APFS role | Persistent volume label |
| --- | --- |
| Monterey System | `Monterey` |
| Monterey Data | `Monterey - Data` |
| 73 MB Recovery helper | `RECOVERY-FIX` |
| Empty SSD development target | `Sequoia-dev` |
| 1 TB Apple data target | `Sequoia Data` |

The former metadata-only `Mac Spare 19GB` container was reclaimed on
2026-07-28. The Monterey SSD physical store grew from `127523901440` to
`146729017344` bytes, while the following `RECOVERY-FIX` partition retained
its exact offset (`255987490816`) and size (`73003008`) in bytes.

An APFS volume rename does not necessarily replace an old OpenCore label in
the SIP-protected Preboot directory. Do not disable SIP to work around that.
Stage the repair helper on the small `RECOVERY-FIX` APFS volume, start local
macOS Recovery, open Utilities > Terminal, and run:

```bash
bash /Volumes/RECOVERY-FIX/fix
```

Source:
[fix-opencore-macos-label-from-recovery.sh](./scripts/fix-opencore-macos-label-from-recovery.sh)

The `fix` launcher uses an absolute Recovery volume path and requires no
`dirname`, `uname`, or working-directory assumptions. If only the main helper
is present, its equivalent direct invocation is:

```bash
bash /Volumes/RECOVERY-FIX/fix-opencore-macos-label-from-recovery.sh \
  <MONTEREY-VOLUME-GROUP-UUID> Monterey
```

The helper searches every APFS Preboot volume but writes only the supplied
volume-group directory. It verifies `boot.efi`, backs up the existing bitmap
and text labels beside it, runs `bless --label`, writes both supported text
labels, and verifies the result.

## Installed-system OpenCore Profile

The machine-specific builder in the separate `hackintosh` repository now has
two explicit profiles:

```text
--profile recovery   # default, hidden direct Recovery boot
--profile installed  # visible five-second graphical multi-OS picker
```

The installed profile:

- sets `ShowPicker=true`, `Timeout=5`, and `HideAuxiliary=false`;
- uses OpenCanopy with the 7050-proven
  `Acidanthera\GoldenGate` icon set at maximum GOP resolution;
- takes `OpenCanopy.efi` from the exact same OpenCore 1.0.7 package as
  `OpenCore.efi`;
- leaves `LauncherOption=Disabled` during staging;
- adds OpenCore 1.0.7 `OpenLegacyBoot.efi`;
- adds read-only `OpenNtfsDxe.efi` for legacy entry labels;
- keeps UEFI Windows 10 discovery;
- keeps Recovery and auxiliary entries visible without pressing Space.

The Windows 10 ESP is labeled `WIN10 EFI`. Its primary
`\EFI\Microsoft\Boot\bootmgfw.efi` and fallback
`\EFI\Boot\bootx64.efi` loaders were backed up and verified byte-identical.
Keep both files. The temporary `WIN10 EFI\EFI\Boot\.contentVisibility` marker
was removed after picker testing so the primary Windows entry remains
discoverable. A text file containing `Disabled` remains at
`MACRECOVERY\EFI\Boot\.contentVisibility`; it hides only the duplicate
fallback picker entry and does not remove that fallback boot path.

The legacy NTFS root has an ASCII `.contentDetails` file containing
`Windows 7`. That label is accepted only after the partition's SP1 kernel,
BCD, `bootmgr`, and `winload.exe` identities pass. It does not prove that
firmware CSM can complete a Windows 7 boot, so retain the physical boot test
as a separate acceptance gate.

OpenCore's own documentation states that `OpenLegacyBoot` can detect and boot
installed legacy systems on firmware with CSM. This matches the 3040's
existing Windows 7 MBR/legacy path. It must still pass a physical boot test
before the picker is made the persistent firmware default.

Promotion order:

1. Mount the exact `MACRECOVERY` ESP by partition UUID.
2. Save its complete EFI tree, `nvram -xp`, and SHA-256 manifest elsewhere.
3. Compare the live EFI with the last accepted manifest.
4. Copy the complete installed candidate and OpenCanopy Resources to a
   staging directory.
5. Verify the candidate SHA-256 manifest and matching OpenCore 1.0.7
   `ocvalidate`.
6. Require the external GoldenGate picker, both OS icons, five-second
   timeout, and all-entry visibility.
7. Promote by same-volume rename, retaining the rollback EFI.
8. Test `Monterey`, `Windows 10`, Recovery, and the legacy Windows 7 entry.
9. Keep the known-good EFI rollback until every path has passed a cold boot.

Do not write Dell `BootOrder` or enable OpenCore `LauncherOption=Full` before
those tests.

The promotion helper enforces those checks and has separate audit/apply modes:

```bash
./promote-optiplex-3040-installed-efi.sh audit \
  --device <MACRECOVERY-diskXsY>

./promote-optiplex-3040-installed-efi.sh apply \
  --device <MACRECOVERY-diskXsY> \
  --candidate ~/Downloads/EFI-installed \
  --manifest ~/Downloads/EFI-installed.SHA256SUMS \
  --ocvalidate ~/Downloads/ocvalidate \
  --confirm PROMOTE-3040-INSTALLED-EFI
```

Source:
[promote-optiplex-3040-installed-efi.sh](./scripts/promote-optiplex-3040-installed-efi.sh)

Apply mode keeps both a same-volume rollback EFI and an independent backup
under `~/Documents/OptiPlex-3040-EFI-Backups`. It does not set firmware order
or request a restart.

## NTFS Data Migration

Do not add an unsigned NTFS kernel extension just to perform a one-time
migration. Boot Windows 10 and use Windows' native NTFS implementation.

The drive letters below are the audited Windows 10 mapping. They are not
portable identifiers:

| Byte offset | Windows mapping | Label | Policy |
| ---: | --- | --- | --- |
| 1,048,576 | `D:` | `Windows 7` | preserve |
| 107,377,328,128 | `E:` | `data dog` | copy to `G:\data dog`; preserve |
| 405,877,555,200 | `F:` | `data ear` | copy to `G:\data ear`; preserve |
| 703,306,137,600 | `G:` | `data fire` | copy destination; preserve |
| 995,909,173,248 | `R:` | `MACRECOVERY` | preserve |

The running Windows 10 installation is `C:` and is not on this Toshiba disk.
The Windows 7 identity was independently checked from its SP1 kernel version,
boot files, and BCD entry before any data operation. The helper uses these
offsets rather than GPT slot numbers because macOS can renumber slots while
preserving every byte boundary.

Run the PowerShell helper from an elevated Windows PowerShell 5.1 window:

```powershell
.\migrate-optiplex-3040-ntfs-data.ps1 -Mode Audit

.\migrate-optiplex-3040-ntfs-data.ps1 `
  -Mode Copy `
  -SetLabels `
  -FullHash
```

Source:
[migrate-optiplex-3040-ntfs-data.ps1](./scripts/migrate-optiplex-3040-ntfs-data.ps1)

The helper rediscovers exactly one Toshiba `DT01ACA100` 1 TB GPT disk and
requires its audited partition geometry. It copies with `robocopy` without
`/MIR` or any delete option, skips only Windows metadata directories, compares
every source and destination relative path and length, and optionally computes
SHA-256 for every file. It writes a JSON verification record under
`G:\DISK-MIGRATION` and never deletes or formats a source partition.

The final-path verification record is
`G:\DISK-MIGRATION\verified-20260728-054629.json`, SHA-256
`2b409c6806d833c1134a03cf603fc87a4e87c8b491136552a50ca8459a403c9c`.
Its accepted trees are:

| Source | Destination | Files | Bytes | SHA-256 result |
| --- | --- | ---: | ---: | --- |
| `E:\` | `G:\data dog` | 20,039 | 6,505,404,159 | every file passed |
| `F:\` | `G:\data ear` | 1,098 | 6,661,498,278 | every file passed |

The folders were renamed on the same NTFS volume after the first pass. Their
NTFS file IDs remained unchanged, and a second full-hash pass produced the
final-path record above.

After the first full-hash copy passed, partition 3 was shrunk in Windows while
retaining `F:` and its NTFS filesystem. The post-staging layout was:

| Region after `E:` | Size | State |
| --- | ---: | --- |
| `F:` data ear | `6,838,812,672` bytes | preserved NTFS |
| reserved gap | `70.6328` GiB | unallocated |
| Apple data staging | `200` GiB | APFS GPT type, unformatted |
| `G:` data fire | `292,603,035,648` bytes | preserved NTFS |

The Apple partition starts at byte `488,557,772,800` and ends exactly where
data fire begins. It was initially left unformatted. To activate that state:

1. restart into Monterey;
2. save `diskutil list` and read-only `gpt show` evidence;
3. rediscover the Toshiba disk by model and size, not a cached `diskX` name;
4. identify the exact 200 GiB partition by start, size, and APFS GPT type;
5. run the guarded helper in audit mode;
6. format only that partition as APFS with a readable data-volume label;
7. test write, unmount, remount, and another cold boot;
8. leave the adjacent 70.6328 GiB gap unallocated.

```bash
./activate-optiplex-3040-apple-data.sh audit

./activate-optiplex-3040-apple-data.sh \
  apply FORMAT-3040-APPLE-DATA
```

Source:
[activate-optiplex-3040-apple-data.sh](./scripts/activate-optiplex-3040-apple-data.sh)

The helper performs steps 3 through 6 and refuses any disk whose model,
whole-disk size, partition offset, partition size, or GPT content type differs
from this record. A partition created with the APFS GPT type in Windows can
appear in Monterey as an empty APFS Physical Store without a valid container.
In that exact state, the helper:

1. requires an empty filesystem and volume name;
2. reclaims only that physical store with `diskutil apfs deleteContainer
   -force`;
3. accepts Monterey's resumable `Apple_KFS` state;
4. creates a new APFS container;
5. adds the `Mac Data` APFS volume.

It also discovers the partition by geometry. Windows called the new GPT entry
partition 6, while macOS exposed the same physical region as `disk3s4`; neither
transient number is hard-coded.

The accepted result on 2026-07-28 was:

| Field | Value |
| --- | --- |
| Physical store | `disk3s4`, 214,748,364,800 bytes |
| APFS container | 214,748,364,800 bytes |
| APFS volume | `Mac Data` |
| Reserved adjacent gap | 75.8 GB decimal / 70.6328 GiB |

After it succeeds, independently:

1. test a write on `Mac Data`;
2. unmount and remount it;
3. cold boot once;
4. confirm that the adjacent 70.6328 GiB gap is still unallocated.

Disk identifiers such as `disk2` and `disk4` can change at every boot. Never
put a transient `diskXsY` value into a reusable erase command.

## Sequoia Preparation Only

Apple's full-installer catalog offered Sequoia `15.7.8` build `24G824` on
2026-07-28. The complete installer and private EFI candidate are staged on
`Mac Data` in the exact 200 GiB Toshiba APFS physical store described above.
The boot target is the empty `Sequoia-dev` APFS volume in the Samsung SSD
container, not the slower 1 TB disk. The adjacent 70.6328 GiB unallocated
Toshiba gap remains untouched.

Keep the complete machine-specific EFI in ignored private storage. Before
using it as a candidate:

1. verify every file against its SHA-256 manifest;
2. run the matching OpenCore 1.0.7 `ocvalidate`;
3. copy the complete candidate to the `Mac Data` staging volume;
4. pass its private `config.plist` path through `EFI_CONFIG`.

Never add PlatformInfo values or the complete EFI tree to this public
repository.

Prepare the SSD layout separately from the installer. Start with a read-only
audit:

```bash
./prepare-optiplex-3040-sequoia-ssd.sh audit
```

Apply only after checking the reported Samsung and Toshiba models, byte
geometry, volume usage, and labels:

```bash
sudo ./prepare-optiplex-3040-sequoia-ssd.sh \
  apply PREPARE-3040-SEQUOIA-SSD
```

Source:
[prepare-optiplex-3040-sequoia-ssd.sh](./scripts/prepare-optiplex-3040-sequoia-ssd.sh)

The helper accepts only two exact layouts: the audited pre-expansion layout or
the completed layout. Before deleting the spare container, it mounts both the
spare and development target read-only, rejects any entry beyond known macOS
metadata, and enforces a 100 MB usage ceiling. It records `diskutil` maps and
per-partition plist geometry before and after the change. Raw `gpt` output is
also recorded when Monterey permits raw-device access.

The accepted result is:

| Item | Accepted result |
| --- | --- |
| SSD APFS physical store | `146729017344` bytes |
| SSD target | `Sequoia-dev`, empty APFS volume |
| SSD free space after preparation | approximately 95.7 GB |
| Monterey volume group | unchanged in the same SSD container |
| Recovery helper | original offset and size unchanged |
| 1 TB volume | `Sequoia Data` |
| Installer staging | `Mac Data/Upgrade-Staging/Sequoia` |

The helper does not open an installer, select a startup disk, or reboot.

Run the combined disk, target, EFI, and staged-installer audit:

```bash
EFI_CONFIG="/path/to/private/EFI/OC/config.plist" \
  ./stage-optiplex-3040-sequoia.sh audit
```

After the target and EFI audit pass, download and verify without starting:

```bash
EFI_CONFIG="/path/to/private/EFI/OC/config.plist" \
  ./stage-optiplex-3040-sequoia.sh fetch
```

Source:
[stage-optiplex-3040-sequoia.sh](./scripts/stage-optiplex-3040-sequoia.sh)

The fetch mode:

- requests exactly Sequoia `15.7.8` through Apple's `softwareupdate`;
- verifies Apple code signatures on `InstallAssistant` and
  `startosinstall`;
- verifies `SharedSupport.dmg`;
- mounts the disk image read-only and requires installer metadata for version
  `15.7.8`, build `24G824`;
- copies the verified app to
  `/Volumes/Mac Data/Upgrade-Staging/Sequoia`;
- verifies the staged copy again and records hashes in `status.txt`;
- removes the temporary copy from the Monterey SSD;
- requires the exact expanded Samsung SSD geometry and the empty
  `Sequoia-dev` target;
- requires `Sequoia Data` on the audited Toshiba APFS store;
- never opens the app, executes `startosinstall`, chooses a startup disk, or
  restarts.

The separate EFI candidate must contain `-no_compat_check`,
`revpatch=sbvmm`, `-igfxsklaskbl`, RestrictEvents, and WhateverGreen before
fetch mode proceeds. These checks are preparation evidence, not proof that
this unsupported hardware will complete a Sequoia boot.

## Windows 10 Automatic Sign-in

Windows 10 automatic sign-in uses Microsoft's signed Sysinternals Autologon
3.10, not a plaintext `DefaultPassword` registry value. Verify after enabling:

```powershell
Get-ItemProperty `
  'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' `
  AutoAdminLogon,DefaultUserName,DefaultDomainName

$winlogon = Get-ItemProperty `
  'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$winlogon.PSObject.Properties.Name -contains 'DefaultPassword'
```

The final expression must return `False`. Test one complete restart and use
`query user` to confirm the intended local account owns the interactive
session. Autologon is physical convenience, not a security boundary: an
administrator can retrieve the LSA secret. Run the same signed Autologon tool
and select **Disable** to undo it.

The 2026-07-28 acceptance restart passed: Windows 10 booted at 14:00 local
time, Explorer and the local `lachlan` console session started automatically,
and no plaintext `DefaultPassword` value existed. UU Remote `4.34.0.8979`
also started its signed service, server, health monitor, and interactive
client. Its password-free scheduled task is `UU Remote - Interactive Client`
with an Interactive logon principal; do not add a duplicate startup task.

## Windows 11 Preparation Only

Windows 11 execution remains blocked on this machine. The audited OptiPlex
3040 has an Intel Core i7-6700, no detected TPM, and Secure Boot disabled for
the OpenCore multi-boot path. Microsoft does not list this CPU as supported,
so the hardware does not pass the normal Windows 11 minimum gates.

From elevated Windows PowerShell 5.1, audit without downloading:

```powershell
.\stage-optiplex-3040-windows11.ps1 -Mode Audit
```

To stage only Microsoft's signed readiness tools on the exact `Data Fire`
partition:

```powershell
.\stage-optiplex-3040-windows11.ps1 -Mode Fetch
```

Source:
[stage-optiplex-3040-windows11.ps1](./scripts/stage-optiplex-3040-windows11.ps1)

The helper rediscovers the Toshiba disk and exact `G:` geometry, writes its
record under `G:\UPGRADE\Windows11-25H2`, verifies Microsoft Authenticode
signatures, records SHA-256 hashes and the hardware audit, and marks
`UpgradeStarted=false`. It never executes Media Creation Tool, PC Health
Check, an installer, a compatibility bypass, or a registry change.

The accepted staged files on 2026-07-28 were:

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `MediaCreationTool-Windows11-25H2.exe` | 21,591,048 | `e887dfff70baf09a8c1debfe8c304dd9f2d9652fae8b7c83b3c24554a79bbd7f` |
| `WindowsPCHealthCheckSetup.msi` | 14,348,288 | `df9f81457e7fc9d670eb9a329ed55e3d7ba2de4dc4d71e7fcc246239d27bef04` |

Do not enable Secure Boot, apply unsupported-hardware bypasses, or run either
file until OpenCore, backups, rollback media, and Microsoft support tradeoffs
have been reviewed separately.

## OpenCore Default Selection

The Dell firmware entry `UEFI: TOSHIBA DT01ACA100` points to
`R:\EFI\BOOT\BOOTx64.efi` on `MACRECOVERY`. Put that firmware entry before
Windows Boot Manager, then let OpenCore apply its own five-second timeout.

OpenCore determines the default OS from routed UEFI BootOrder, not from picker
display order. On this firmware, both `systemsetup -setstartupdisk` and
`bless --mount / --setBoot` fail while SIP remains enabled. Do not disable SIP.
Use the supported picker action once instead:

1. select `Monterey`;
2. press `Ctrl+Enter`;
3. if the firmware does not report Ctrl, hold `+` while pressing Enter;
4. let Monterey boot;
5. restart without input and verify Monterey is selected after five seconds.

`Misc -> Security -> AllowSetDefault` and `PollAppleHotKeys` must remain
enabled for this operation. Selecting Windows with ordinary Enter must not
change the saved default.

The 2026-07-28 live verification found `ShowPicker=true`, `Timeout=5`,
`AllowSetDefault=true`, and `PickerMode=External`. The saved NVRAM target
resolved exactly to the Monterey APFS volume group and its Preboot
`boot.efi`; no Recovery or one-time boot override was present.

For the separate investigation of remote stalls, automatic major updates, UU
wakeups, iCloud and Photos load, and the reversible stability guard, see
[OptiPlex 3040 and 7050 macOS stability](./macos-remote-stability-3040-7050.md).

## Acceptance Checks

```bash
ssh -o BatchMode=yes optiplex-3040-macos 'sw_vers'
nc -vz OptiPlex-3040-macOS.local 22
nc -vz OptiPlex-3040-macOS.local 5900
nc -vz OptiPlex-3040-macOS.local 3283
```

On the Mac:

```bash
systemsetup -getremotelogin
pmset -g custom
nvm --version
node --version
npm --version
codex --version
codesign -dv --verbose=2 /Applications/UURemote.app
```

The final acceptance gate is a cold boot of every picker entry. SSH and remote
desktop checks do not prove a boot path that has never been selected.

## Primary References

- [Apple: current macOS versions](https://support.apple.com/en-us/109033)
- [Apple: macOS Sequoia compatible computers](https://support.apple.com/en-us/120282)
- [OpenCorePkg 1.0.7 release](https://github.com/acidanthera/OpenCorePkg/releases/tag/1.0.7)
- [nvm installation and release guidance](https://github.com/nvm-sh/nvm)
- [Homebrew UU Remote cask record](https://formulae.brew.sh/cask/uuremote)
- [OpenAI Codex CLI](https://developers.openai.com/codex/cli)
