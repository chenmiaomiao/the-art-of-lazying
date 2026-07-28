# OptiPlex 3040 macOS Post-install and Sequoia Staging

Status date: 2026-07-28

## Scope

This runbook starts after Monterey Setup Assistant has created the local
administrator `lachlan`. It covers remote access, development tools, readable
volume and picker names, and a staged Sequoia installer.

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
- remove Monterey Recovery or either Windows installation.

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
  --peer-host <ubuntu-ip>
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
- prevents unattended full macOS upgrades while keeping critical and
  configuration-data updates enabled;
- verifies and installs UU Remote;
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

Verify:

```bash
pgrep -fal '^/Applications/UURemote.app'
sudo launchctl print system/com.netease.uuremote.daemon
launchctl print "gui/$(id -u)/com.netease.uuremote.agent"
```

Test viewing, mouse input, ordinary phone-keyboard text, modifier keys, and
reconnection after logout separately.

## Apple Remote Desktop and VNC

The post-install script configures Apple's native Remote Management service
with observe and control privileges for `lachlan`. It uses macOS account
authentication and does not store a separate VNC password in a script.

Verify locally:

```bash
sudo lsof -nP -iTCP:5900 -sTCP:LISTEN
sudo lsof -nP -iTCP:3283 -sTCP:LISTEN
```

Connect from a Mac with Screen Sharing:

```text
vnc://lachlan@OptiPlex-3040-macOS.local
```

Remmina or another VNC client can use the same host. Keep VNC limited to the
trusted LAN; do not forward TCP 5900 from the internet.

## Volume Naming

Audit before renaming:

```bash
diskutil apfs listVolumeGroups
diskutil info /
diskutil info /System/Volumes/Data
```

Only when `/` is the newly installed APFS system volume and its current name
is `No Name` or `Untitled`, rename that mounted root:

```bash
sudo diskutil renameVolume / "Macintosh HD"
```

Re-run the audit and confirm the System/Data volume group still has the same
container and volume UUIDs. Leave the dedicated `MACRECOVERY` label unchanged;
it identifies the rollback ESP.

## Installed-system OpenCore Profile

The machine-specific builder in the separate `hackintosh` repository now has
two explicit profiles:

```text
--profile recovery   # default, hidden direct Recovery boot
--profile installed  # visible eight-second multi-OS picker
```

The installed profile:

- sets `ShowPicker=true`, `Timeout=8`, and `HideAuxiliary=true`;
- leaves `LauncherOption=Disabled` during staging;
- adds OpenCore 1.0.7 `OpenLegacyBoot.efi`;
- adds read-only `OpenNtfsDxe.efi` for legacy entry labels;
- keeps UEFI Windows 10 discovery;
- keeps Recovery available by pressing Space.

OpenCore's own documentation states that `OpenLegacyBoot` can detect and boot
installed legacy systems on firmware with CSM. This matches the 3040's
existing Windows 7 MBR/legacy path. It must still pass a physical boot test
before the picker is made the persistent firmware default.

Promotion order:

1. Mount the exact `MACRECOVERY` ESP by partition UUID.
2. Save its complete EFI tree, `nvram -xp`, and SHA-256 manifest elsewhere.
3. Compare the live EFI with the last accepted recovery manifest.
4. Copy the complete installed candidate to a staging directory.
5. Run matching OpenCore 1.0.7 `ocvalidate`.
6. Promote by same-volume rename, retaining the rollback EFI.
7. Boot OpenCore once with Dell's one-time boot selection.
8. Test `Macintosh HD`, `Windows 10`, and the legacy Windows 7 entry.
9. Set OpenCore persistent only after all three paths and rollback pass.

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

## Stage Sequoia

Apple's current Sequoia maintenance release in this record is `15.7.7`.
The generated EFI already has the reviewed Kaby Lake HD 530 identity,
WhateverGreen, RestrictEvents, `-no_compat_check`, and `revpatch=sbvmm`.
Apple's Sequoia compatibility list does not include `iMac17,1`; this remains an
unsupported Hackintosh upgrade even though the same graphics strategy is
already proven on the separate 7050.

Audit only:

```bash
EFI_CONFIG=/Volumes/MACRECOVERY/EFI/OC/config.plist \
  ./stage-optiplex-3040-sequoia.sh audit
```

Download and verify, without launching:

```bash
EFI_CONFIG=/Volumes/MACRECOVERY/EFI/OC/config.plist \
  ./stage-optiplex-3040-sequoia.sh fetch
```

Source:
[stage-optiplex-3040-sequoia.sh](./scripts/stage-optiplex-3040-sequoia.sh)

The script requires at least 35 GiB free, checks the EFI compatibility
settings, asks Apple's `softwareupdate` for the exact full installer, verifies
the app signature and payload, and writes a status record whose final field is
`upgrade_started=no`.

Fetching is preparation. Before a later upgrade:

1. make a tested Monterey backup;
2. preserve the accepted EFI and NVRAM evidence on another machine;
3. confirm UU, SSH, VNC, Ethernet, USB, graphics acceleration, audio, restart,
   and cold boot on Monterey;
4. keep a physical display and keyboard attached;
5. start the installer only in a separate maintenance window.

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
