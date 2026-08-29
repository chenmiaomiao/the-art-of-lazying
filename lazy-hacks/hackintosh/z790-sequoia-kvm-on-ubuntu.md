# Isolated Sequoia KVM on an Ubuntu Z790 workstation

Status date: 2026-08-29

## Result so far

An isolated OpenCore/QEMU profile was built for a 13th/14th-generation Intel
Ubuntu workstation with 128 GB RAM. The Apple-verified Sequoia recovery booted
successfully with KVM acceleration, a blank 512 GiB virtual disk was erased as
GUID/APFS, and the Sequoia installer started writing to it. Final installation
and post-setup acceptance remain pending at this checkpoint.

The canonical scripts and detailed runbook live in
[`lachlanchen/hackintosh`](https://github.com/lachlanchen/hackintosh), in
`scripts/hackintosh-kvm.sh` and `docs/24-z790-kvm-sequoia.md`. Large runtime
files, Apple media, generated VM identity, writable NVRAM, and logs stay on the
private SATA filesystem and never enter Git.

## Why Sequoia, not Tahoe

Current OSX-KVM can fetch Tahoe media and current OpenCore releases contain
Tahoe compatibility work. That does not make this particular workstation a
tested Tahoe host. The existing recovery repository is validated around
Sequoia 15.7.7, so the conservative sequence is:

1. install and accept Sequoia;
2. make a qcow2 checkpoint while the VM is stopped;
3. test a later major macOS release in a clone, not in the only working disk.

The recovery image fetched during this run identifies itself as Sequoia
15.4.1 (`24E263`). That observed fact must not be rewritten as 15.7.7. Update
the installed guest to the tested Sequoia point release as a separate,
reversible operation.

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

The unit is linked for clean ownership but intentionally not enabled at boot.
One heavy VM should not silently claim workstation resources after a reboot.
The installer action also targets the canonical `/run/user/UID/bus`; this
avoids misleading `systemctl --user` failures from an XRDP shell attached to a
different per-session D-Bus address.

The private console is:

```text
http://127.0.0.1:6141/vnc.html?autoconnect=1&resize=scale
```

Tunnel that loopback port over SSH when operating remotely. Never expose raw
VNC, noVNC, QMP, or a guest browser profile to the LAN or Internet.

## First-boot evidence and one corrected defect

The first QEMU attempt exited cleanly because the converted recovery image was
attached read-only to an IDE device. QEMU reported `Block node is read-only`.
The generated recovery image is a private working copy, so the launcher now
attaches that copy writable while keeping the upstream OpenCore image in
snapshot mode. No host/KVM setting needed to change.

The second attempt reached OpenCore, booted Recovery, formatted only QEMU
`disk0`, and started installation. `kvm.ignore_msrs` remained at its existing
host value because there was no unhandled-MSR evidence. This is the preferred
diagnostic order: correct the observed launch error before applying generic
upstream host tweaks.

Two automation-specific upstream assumptions were also made explicit. In
`--action download` mode, `--shortname` does not choose the product, so the
launcher passes the Sequoia board, anonymous MLB, and default OS type directly.
The chunk verifier expects an interactive terminal width; the launcher supplies
a fixed width under systemd/SSH while retaining the complete cryptographic
chunk verification.

## Validation and recovery

```bash
bash -n scripts/hackintosh-kvm.sh
systemd-analyze --user verify scripts/hackintosh-kvm.service
git diff --check
./scripts/hackintosh-kvm.sh verify
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
- [QEMU disk images](https://www.qemu.org/docs/master/system/images.html)
- [QEMU invocation and memory backends](https://www.qemu.org/docs/master/system/invocation.html)
- [Dortania NVIDIA GPU support](https://dortania.github.io/GPU-Buyers-Guide/modern-gpus/nvidia-gpu.html)
- [Dortania Intel GPU support](https://dortania.github.io/GPU-Buyers-Guide/modern-gpus/intel-gpu.html)
- [Apple macOS Sequoia software license](https://www.apple.com/legal/sla/docs/macOSSequoia.pdf)
