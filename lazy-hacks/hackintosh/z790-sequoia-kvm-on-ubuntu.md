# Isolated Sequoia KVM on an Ubuntu Z790 workstation

Status date: 2026-08-30

## Verified result

An isolated OpenCore/QEMU profile was built for a 13th/14th-generation Intel
Ubuntu workstation with 128 GB RAM. The Apple-verified Sequoia recovery booted
successfully with KVM acceleration, a blank 512 GiB virtual disk was erased as
GUID/APFS, and both installer stages completed. Setup Assistant was completed,
and the installed guest reports Sequoia 15.7.9 (`24G830`). The recovery
environment itself was 15.4.1; the online installer delivered the newer,
current Sequoia security release.

OpenCore automatically selected the installer volume after the first reboot.
At Setup Assistant, the sparse qcow2 still presented 512 GiB to macOS while
occupying only 32.8 GiB on SATA. QEMU/noVNC remained healthy, its three ports
were loopback-only, and the 128 GB host retained about 77 GiB of available
memory.

The canonical scripts and detailed runbook live in
[`lachlanchen/hackintosh`](https://github.com/lachlanchen/hackintosh), in
`scripts/hackintosh-kvm.sh` and `docs/24-z790-kvm-sequoia.md`. Large runtime
files, Apple media, generated VM identity, writable NVRAM, and logs stay on the
private SATA filesystem and never enter Git.

## Why Sequoia, not Tahoe

Current OSX-KVM can fetch Tahoe media and current OpenCore releases contain
Tahoe compatibility work. That does not make this particular workstation a
tested Tahoe host. The conservative sequence is:

1. install and accept Sequoia;
2. make a qcow2 checkpoint while the VM is stopped;
3. test a later major macOS release in a clone, not in the only working disk.

The recovery image identifies itself as Sequoia 15.4.1 (`24E263`), while
`sw_vers` in the installed guest reports 15.7.9 (`24G830`). Apple lists 15.7.9
as the current Sequoia security update and recommends it for Sequoia users.
Do not downgrade it to the earlier 15.7.7 checkpoint.

Apple's Sequoia software license restricts macOS virtualization to
Apple-branded hardware. This is therefore an unsupported interoperability
experiment, not an Apple-supported deployment.

## Hardware conclusion

| Host component | Compatibility decision |
| --- | --- |
| Intel Core i9-14900K | KVM/VT-x is usable; present a supported virtual CPU model |
| Intel UHD 770 | Raptor Lake graphics are unsupported by macOS; no passthrough |
| NVIDIA RTX 4090 | Ada Lovelace is unsupported by macOS; no passthrough |
| SATA SSD | Safe location for private sparse VM state |
| 128 GB host RAM | Enough for a 16 GiB guest while preserving workstation headroom |

The VM uses `vmware-svga`. It provides a functional framebuffer for setup and
ordinary software-rendered use, but no Metal acceleration. Passing through
either host GPU would add reset/IOMMU risk without producing a supported macOS
graphics path.

## What “dynamic” means here

The virtual disk is genuinely thin-provisioned:

```bash
qemu-img create -f qcow2 \
  -o compat=1.1,lazy_refcounts=on,preallocation=off \
  macOS-Sequoia.qcow2 512G
```

The guest sees 512 GiB, while the host file starts at a few hundred KiB and
grows only as blocks are written. Always compare `qemu-img info` with `du`.

Memory is different. A launch gives macOS a fixed 16 GiB ceiling, but QEMU
uses `memory-backend-ram,prealloc=off`, so host pages are committed on demand.
macOS has no dependable balloon/hotplug route in this profile. Change the next
launch explicitly:

```bash
HACKINTOSH_KVM_RAM_GIB=24 ./scripts/hackintosh-kvm.sh run
```

Call this configurable, demand-backed memory—not automatic RAM resizing.

## Isolation architecture

```text
browser on Ubuntu
  -> 127.0.0.1-only noVNC
  -> 127.0.0.1-only QEMU VNC
  -> OpenCore + Sequoia recovery
  -> sparse qcow2 on SATA

guest network
  -> QEMU user-mode NAT
  -> normal Ubuntu network path
```

There is no host block-device argument, VFIO device, TAP bridge, router change,
host EFI edit, bootloader edit, NVIDIA change, or CPU-core-policy change. The
guest SSH forward is loopback-only as well.

## Reusable workflow

Install the host packages:

```bash
sudo apt install qemu-system-x86 qemu-utils ovmf dmg2img \
  p7zip-full genisoimage swtpm novnc websockify
```

Keep a private config outside Git:

```bash
RUNTIME_ROOT=/path/on/sata/VirtualMachines/Hackintosh-KVM
RAM_GIB=16
DISK_SIZE=512G
CPU_CORES=4
CPU_THREADS=2
VNC_DISPLAY=41
NOVNC_PORT=6141
SSH_PORT=2224
```

Then use the canonical helper:

```bash
./scripts/hackintosh-kvm.sh fetch
./scripts/hackintosh-kvm.sh verify
./scripts/hackintosh-kvm.sh install-service
./scripts/hackintosh-kvm.sh start
./scripts/hackintosh-kvm.sh status
```

## Apple Account repair without publishing identity

The first Apple Account attempt failed with **Verification Failed — An unknown
error occurred**. The OpenCore template still carried public placeholder
serial/MLB/UUID/ROM values, and although the working Ethernet interface was
`en0`, `ioreg` initially showed no `built-in` property. QEMU's live PCI
inventory located that interface at `PciRoot(0x0)/Pci(0x4,0x0)`.

The canonical repair keeps the supported `iMac19,1` model and creates one
stable private identity with OpenCore 1.0.7 `macserial`. It synchronizes QEMU
MAC, ROM, QEMU UUID, OpenCore SystemUUID, serial, and MLB; adds `built-in = 01`
to the observed network path; validates with matching `ocvalidate`; and builds
a separate private OpenCore qcow2. The hash-pinned template image stays
unchanged.

Run only while the guest is stopped:

```bash
./scripts/hackintosh-kvm.sh apple-services
./scripts/hackintosh-kvm-apple-services.sh verify
```

The helper is idempotent and refuses to rotate a valid identity. All identity
values, configs, EFI images, writable firmware, and backups remain mode `0600`
under the private SATA runtime; Git receives only code and redacted method.
Before applying the change, preserve a complete stopped qcow2 checkpoint.

The rollback selector is reversible and does not delete the private image:

```bash
./scripts/hackintosh-kvm-apple-services.sh rollback
./scripts/hackintosh-kvm-apple-services.sh enable
```

Both commands require a stopped guest. Rollback restores the prior QEMU
MAC/UUID and selects the untouched template; enable restores the validated
private pair. No NVRAM reset is part of this repair.

The first retry after that repair still failed, but the unified log made the
remaining boundary much clearer. The default route was built-in `en0`, the
guest clock was correct, and Apple's endpoint returned HTTP 200. `akd` instead
failed during Anisette/device provisioning: routing error `-45061`,
`AKAnisetteError -8008`, BAA attestation error `-10000`, and an HTTP 401 from
the provisioning-finish request. The generic dialog was therefore not evidence
of a broken Internet connection.

The small `com.apple.akd` cache was backed up to owner-only private state,
removed, and regenerated by a clean guest reboot. No account database,
keychain, identity, or OpenCore NVRAM was deleted. The cache refresh alone did
not clear DeviceCheck.

The next stopped-VM repair used the two exact, length-preserving kernel cstring
swaps audited from
[`osx-proxmox-next` v0.31.2 at commit `0f5a16a`](https://github.com/lucid-fabrics/osx-proxmox-next/tree/0f5a16ad1e294f6d4c0c67e976be323fd3a13eb5).
Each source byte sequence occurred exactly once in the installed Sequoia
kernel. OpenCore limits both entries to Darwin 24 (`24.0.0`–`24.99.99`) with
`Count = 1`, so they are not silently applied to Sonoma, Tahoe, or an unknown
future kernel. The pair swaps the names behind `hv_vmm_present` and
`hibernatecount`; after reboot the guest reported `kern.hv_vmm_present = 0`
and `kern.hibernatecount = 1`.

For an existing private identity, refresh only while the guest is stopped:

```bash
./scripts/hackintosh-kvm-apple-services.sh refresh
./scripts/hackintosh-kvm-apple-services.sh verify
```

The helper validates the current identity, preserves one owner-only pre-patch
config/EFI/manifest backup, rebuilds and round-trips the EFI, runs matching
`ocvalidate`, checks hashes and qcow2 integrity, and never rotates serial, MLB,
ROM, MAC, or SystemUUID. New private identities receive the same scoped entries
during `prepare`.

The QEMU launcher also persists a separate owner-only `vm-generation-id` and
passes it through the `vmgenid` device on every normal boot. The ID is generated
once and validated rather than changing whenever the service restarts.

The post-patch authentication result established a useful boundary:

- routing, DNS, TCP, TLS 1.3, and the request to Apple succeeded;
- `akd` received HTTP 200;
- the prior Anisette/BAA/HTTP 401 chain did not recur;
- SRP authentication then returned server error `-20101`, while the UI
  reported an incorrect account or password;
- 2FA was not reached, and the rejected password was cleared from the form.

This verified that the local DeviceCheck path changed, but sign-in was not
complete at that checkpoint. The operator later completed Apple Account login
manually. An authenticated App Store purchase and download then verified the
Media & Purchases path. That is not a claim that every iCloud service was
tested. Do not answer a credential-level rejection by rotating identity,
resetting NVRAM, or automating retries.

## Xcode 26.3 without the crashing PackageKit path

The current App Store listing offered Xcode 26.6, which requires a newer macOS
release. Apple's compatibility table identifies Xcode 26.3 as the last release
supported on Sequoia 15.6 or later, so the App Store's **Download an older
version** path selected Xcode 26.3 (`17C529`).

The download completed, but every normal installation route failed the same
way. `installd` crashed with `EXC_BAD_ACCESS`/`SIGSEGV` inside PackageKit's
`actualFileInstallPathsViolatingReadOnlySystemLocationsEvaluatingDestinationPath`
analysis. The client surfaced only `PKInstallErrorDomain Code=200`, “An error
occurred connecting to the installation service.” More than 500 GB was free,
authentication succeeded, and both `mas` and native App Store paths reproduced
the stack. It was not a disk-space or incomplete-download problem.

The effective recovery retained the authenticated package before App Store
cleanup. During `mas install 497799835`, a root shell hard-linked the active
package and its receipt from the per-user `com.apple.AppStore/497799835` cache
to an owner-only capture directory. A hard link shares the same blocks and does
not double a multi-gigabyte download. After PackageKit failed, the retained
package passed `pkgutil --check-signature` as **signed by Apple for the App
Store** with a trusted timestamp. Its SHA-256 was:

```text
89d9e6b90fead5da4b40fda0b26a8f32e2f9889fb0b2d9c594c3820c13b1af58
```

Do not substitute a raw unauthenticated CDN download. That object remained
encrypted and could not be opened as an Apple package.

The verified package was expanded without invoking `installer`. Its payload is
Apple's `pbzx` format, supported by Sequoia's built-in `aa` tool:

```bash
pkgutil --expand Xcode-26.3-AppStore.pkg Xcode-26.3-expanded
mkdir -m 700 Xcode-26.3-staging
aa extract \
  -i Xcode-26.3-expanded/Xcode.pkg/Payload \
  -d Xcode-26.3-staging \
  -t 4 -wt 2 -enable-dedup -enable-holes

spctl --assess --type execute -vv \
  Xcode-26.3-staging/Applications/Xcode.app
codesign --verify --deep --strict --verbose=2 \
  Xcode-26.3-staging/Applications/Xcode.app
```

Gatekeeper accepted the bundle as a Mac App Store application from Apple, and
deep verification reported `valid on disk` and `satisfies its Designated
Requirement`. Only then was it installed and initialized:

```bash
sudo mv Xcode-26.3-staging/Applications/Xcode.app /Applications/Xcode.app
sudo chown -R root:wheel /Applications/Xcode.app
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch
xcodebuild -version
```

The result is Xcode 26.3 build `17C529`. It already bundles macOS 26.2, iOS
26.2, and watchOS 26.2 SDKs. The storage-scoped policy is to add only universal
iOS and watchOS simulator runtimes on this Intel guest. Never use
`-downloadAllPlatforms`; tvOS and visionOS runtimes are intentionally omitted.
The package capture, expansion, and staging data used about 5.5 GiB and were
deleted after first-launch verification.

Install only those two runtimes with:

```bash
xcodebuild -downloadPlatform iOS -architectureVariant universal
xcodebuild -downloadPlatform watchOS -architectureVariant universal
xcrun simctl list runtimes
```

The verified registrations are iOS 26.3.1 (`23D8133`) and watchOS 26.2
(`23S303`), each supporting both `x86_64` and `arm64`. Xcode occupies about
11 GiB. The runtime images plus the required Intel dyld caches occupy about
14.0 GiB for iOS and 7.5 GiB for watchOS. No Xcode, `.dmg`, or `.simruntime`
artifact remained in Downloads, and about 448 GiB remained free afterward.
Swift 6.2.4, Apple Clang 17, and a one-line Swift execution test passed.

Registration is verified; simulator graphics performance is not. This KVM
profile has no Metal acceleration, so physical Apple hardware remains the
appropriate final validation target for performance-sensitive applications.

## Keep iCloud online-first without deleting cloud data

iCloud Drive remains enabled and `Optimize Mac Storage` is on. At verification
time the guest contained zero downloaded iCloud Drive files and a zero-size
Photos library, so it already consumed no local cloud-file space.

Use Finder's **Remove Download** for any synchronized item that later becomes
local. Never use `rm` for this purpose: deleting a synced item can delete it
from iCloud and every device. Optimize Mac Storage can retain recent files when
space is abundant. A strict never-sync policy would require disabling **Sync
this Mac**, which is a different tradeoff and was not applied here.

## A usable unattended guest without publishing credentials

The existing account and home directory were preserved. FileVault was off, so
automatic login was enabled and verified across a real reboot. System, display,
disk, standby, hibernation, and Power Nap timers were disabled; screen-saver
idle time was set to zero; and a built-in static wallpaper was applied. The VM
returned directly to the desktop and restored its open windows.

The guest password, dedicated SSH key, AuthKit evidence, and cache backup remain
mode `0600` under the VM's private `state/private/` directory. Public notes use
placeholders only. Prefer an interactive password prompt when enabling auto
login:

```bash
sudo sysadminctl -autologin set -userName <short-name> -password -
```

On this Sequoia guest that command reached `SACSetAutoLoginPassword error:22`.
The fallback used the standard loginwindow auto-login credential generated from
the private password, then verified the result with `sysadminctl -autologin
status`. This convenience weakens local-at-console security because the stored
credential is obfuscated rather than encrypted.

Sequoia also rejected `systemsetup -setremotelogin on` without Terminal Full
Disk Access. The narrower solution enabled and bootstrapped the built-in
`ssh.plist` with `launchctl`, installed a dedicated public key, and retained
QEMU's loopback-only host forward. At the OpenCore picker, Control+Enter on
`Macintosh HD` made the real system the remembered default without clearing
NVRAM.

The unit is linked for clean ownership but intentionally not enabled at boot.
One heavy VM should not silently claim workstation resources after a reboot.
The installer action also targets the canonical `/run/user/UID/bus`; this
avoids misleading `systemctl --user` failures from an XRDP shell attached to a
different per-session D-Bus address.

The private console is:

```text
http://127.0.0.1:6141/vnc.html?autoconnect=1&resize=scale&layoutsafe=1
```

Tunnel that loopback port over SSH when operating remotely. Never expose raw
VNC, noVNC, QMP, or a guest browser profile to the LAN or Internet.

## Preserve punctuation across JIS, UU, RDP, noVNC, and macOS

The real input chain is not one keyboard. It can begin with a Japanese
MacBook, a phone keyboard, UU Remote's computer-keyboard panel, or a Windows
keyboard, then cross RDP into Ubuntu before noVNC reaches the macOS KVM. A
global JIS or U.S. hard-code therefore fixes one path by breaking another.

The observed mismatch had a narrower cause. Ubuntu's active X11 desktop used
XKB `jp`; QEMU exposed a generic USB keyboard; and macOS used ABC/U.S. noVNC
1.3.0 negotiated QEMU's extended key event, which sends physical key positions
and assumes the guest layout matches the client. Thus JIS Shift+7, intended as
apostrophe, reached the U.S. guest position for ampersand. A keysym-only test
was also insufficient because the required target Shift state was lost.

The repository now carries a hash-pinned patch that translates only printable
ASCII punctuation into explicit U.S. virtual-key chords at the final noVNC to
QEMU boundary. It temporarily normalizes Shift, sends the intended chord, and
restores held Shift keys. Letters, navigation, CJK input methods, and
Control/Alt/Command shortcuts remain on upstream handling. No Ubuntu or macOS
global keyboard preference is changed.

Run the idempotent preparation explicitly when validating a deployment:

```bash
./scripts/hackintosh-kvm.sh prepare-novnc
```

The generated web root is private ignored state and occupies about 1.2 MiB;
`/usr/share/novnc` is not modified. The launcher uses it automatically on the
next start. The live running VM was migrated by replacing only its loopback
noVNC proxy, so QEMU, Safari, and guest state never restarted. A transient
proxy is bound to the VM service for the current lifecycle; ordinary future
starts use the launcher directly.

websockify serves static files from its process working directory. Therefore,
if the private web root is regenerated while a proxy is live, the generator
retains that previous 1.2 MiB root until the proxy is restarted. This avoids
breaking an existing browser while still promoting the verified update. A
later preparation removes stale roots once no process owns them.

Browser-level acceptance verified a deliberately mismatched JIS Shift+7 as
apostrophe, plus `@`, brackets, slash, colon, question mark, and the remaining
ASCII punctuation in TextEdit. Append `layoutsafe=0` for immediate upstream
behavior. Clipboard paste remains the safest credential workaround until a
particular remote chain has passed its punctuation test.

## First-boot evidence and one corrected defect

The first QEMU attempt exited cleanly because the converted recovery image was
attached read-only to an IDE device. QEMU reported `Block node is read-only`.
The generated recovery image is a private working copy, so the launcher now
attaches that copy writable while keeping the upstream OpenCore image in
snapshot mode. No host/KVM setting needed to change.

The second attempt reached OpenCore, booted Recovery, formatted only QEMU
`disk0`, completed both installer stages, and reached Setup Assistant.
OpenCore selected the correct installer volume automatically after the first
reboot. `kvm.ignore_msrs` remained at its existing host value because there
was no unhandled-MSR evidence. This is the preferred diagnostic order: correct
the observed launch error before applying generic upstream host tweaks.

Two automation-specific upstream assumptions were also made explicit. In
`--action download` mode, `--shortname` does not choose the product, so the
launcher passes the Sequoia board, anonymous MLB, and default OS type directly.
The chunk verifier expects an interactive terminal width; the launcher supplies
a fixed width under systemd/SSH while retaining the complete cryptographic
chunk verification.

## Validation and recovery

```bash
bash -n scripts/hackintosh-kvm.sh
bash -n scripts/hackintosh-kvm-apple-services.sh
systemd-analyze --user verify scripts/hackintosh-kvm.service
git diff --check
./scripts/hackintosh-kvm.sh verify
./scripts/hackintosh-kvm-apple-services.sh verify
./scripts/hackintosh-kvm.sh status
```

`stop` asks the guest to shut down over a private QMP socket. `force-stop`
first verifies that the PID command line names the exact project qcow2 and
then sends `SIGTERM`. Neither action kills an arbitrary QEMU or noVNC process.

Before copying or compacting qcow2, stop the guest and verify QEMU is gone.
Keep the current and immediately previous verified image; do not accumulate
unbounded installers and snapshots on a shared workstation.

## Primary references

- [OSX-KVM](https://github.com/kholia/OSX-KVM)
- [OpenCore releases](https://github.com/acidanthera/OpenCorePkg/releases)
- [Dortania iServices repair](https://dortania.github.io/OpenCore-Post-Install/universal/iservices.html)
- [`osx-proxmox-next` v0.31.2 audited source](https://github.com/lucid-fabrics/osx-proxmox-next/tree/0f5a16ad1e294f6d4c0c67e976be323fd3a13eb5)
- [QEMU disk images](https://www.qemu.org/docs/master/system/images.html)
- [QEMU invocation and memory backends](https://www.qemu.org/docs/master/system/invocation.html)
- [Dortania NVIDIA GPU support](https://dortania.github.io/GPU-Buyers-Guide/modern-gpus/nvidia-gpu.html)
- [Dortania Intel GPU support](https://dortania.github.io/GPU-Buyers-Guide/modern-gpus/intel-gpu.html)
- [Apple macOS Sequoia software license](https://www.apple.com/legal/sla/docs/macOSSequoia.pdf)
- [Apple macOS Sequoia 15.7.9 security content](https://support.apple.com/en-ca/148171)
- [Apple Xcode system requirements](https://developer.apple.com/xcode/system-requirements/)
- [Apple: work with iCloud Drive files](https://support.apple.com/guide/mac-help/-mchl1a02d711/mac)
- [Apple: optimize Mac storage](https://support.apple.com/guide/mac-help/optimize-storage-space-sysp4ee93ca4/mac)
- [noVNC API: physical `code` versus symbolic `keysym`](https://novnc.com/noVNC/docs/API.html)
- [QEMU extended key event protocol](https://github.com/TigerVNC/tigervnc/blob/master/doc/rfbproto.rst)
- [QEMU keycodemap database](https://github.com/qemu/keycodemapdb/blob/master/data/README)
