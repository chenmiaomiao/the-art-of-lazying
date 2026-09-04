# KVM/QEMU Windows and macOS workstation notes

Status: verified reference updated 2026-09-04

The reusable implementation now lives in
[`lachlanchen/kvm-qemu-workstation`](https://github.com/lachlanchen/kvm-qemu-workstation).
Detailed macOS/OpenCore recovery and identity work remains in
[`lachlanchen/hackintosh`](https://github.com/lachlanchen/hackintosh). This page
records the operational conclusions without publishing VM disks, installers,
credentials, host keys, TPM state, OpenCore identity, or private logs.

## KVM and QEMU in one sentence

KVM is the Linux kernel's hardware-virtualization accelerator; QEMU creates
the virtual computer and emulated devices. QEMU can run without KVM, but KVM
makes x86 guests practical by executing guest CPU instructions on the host CPU.

## Verified Windows result

The workstation completed a lightweight but serviceable Windows 11 Pro guest:

- Ubuntu 24.04 host with QEMU 8.2.2, KVM, OVMF, and swtpm;
- Windows 11 Pro 25H2 build 26200, reduced locally with the regular Tiny11
  builder rather than Tiny11 Core;
- 4 vCPUs, 8 GiB RAM, and a sparse 128 GiB qcow2;
- QEMU VNC behind a short loopback-only noVNC page;
- localhost forwards for RDP and OpenSSH;
- QEMU guest agent and VirtIO guest tools installed and verified;
- two clean shutdown/restart checks after detaching all installer media;
- WeCom installed from its verified WinGet manifest as an application check.

The sparse disk exposes 128 GiB to Windows but consumes only the blocks written
on the host. Windows still requires a valid Microsoft licence; image reduction
does not activate or license it.

## Build provenance

The guest ISO was built locally from signed Microsoft media. The reference run
pinned NTDEV's regular Tiny11 builder at commit
`00e7d8a151a39ccffccab4a267bb81fb3756a01d`. A small public patch adds exact
image-index selection, non-interactive operation, and an `install.esd` guard.
The helper verifies the Microsoft `setup.exe` signature and records the output
SHA-256. Neither Microsoft media nor a prebuilt Tiny11 image belongs in Git.

Tiny11 Core was deliberately rejected because it removes servicing, Windows
Update, and the component store. A small regular Tiny11 install is more useful
than a smaller image that cannot be maintained normally.

## The installer failure that was not an ISO failure

On the reference QEMU 8.2.2/OVMF combination, firmware timed out when starting
both the untouched Microsoft ISO and the locally derived ISO from an emulated
SATA DVD. Reproduction with both images was the key evidence against file
corruption.

The working path attached the same verified ISO twice and read-only:

1. as USB storage, allowing OVMF to expose an EFI filesystem;
2. as SATA optical media, allowing WinPE to find its source files.

The EFI shell fallback was `FS0:\EFI\BOOT\BOOTX64.EFI`. After installation,
Windows Boot Manager handled subsequent starts normally. The public launcher
uses this dual path only before an explicit installed marker exists.

## Daily lifecycle

The dedicated repository exposes one dispatcher:

```text
kvm-workstation windows prepare
kvm-workstation windows start
kvm-workstation windows status
kvm-workstation windows url
kvm-workstation windows stop

kvm-workstation macos status
kvm-workstation macos start
kvm-workstation macos url
```

The Windows implementation lives in the cross-platform repository. macOS
commands delegate to the separately audited Hackintosh launcher, preserving a
single daily command without duplicating private OpenCore identity logic.

Normal Windows stop requests ACPI shutdown through QMP and waits. Force-stop
checks the PID file, QEMU process name, and exact disk path before signalling
the process. The installed marker detaches installer, VirtIO, and bootstrap
media and also lets later verification run without those ISOs.

## Privacy and resource boundaries

- Bind VNC, noVNC, RDP, and guest SSH forwards to `127.0.0.1`.
- Use an authenticated SSH tunnel from another machine; raw VNC is not a
  security boundary.
- Keep one noVNC proxy per guest and reuse it for later review.
- Keep mutable state on a private data disk: qcow2, OVMF variables, TPM state,
  sockets, logs, generated MAC/UUID values, and installers.
- Do not autostart heavy guests on a shared workstation. Check memory, swap,
  active QEMU processes, and project-owned heavy jobs first.
- Sparse disk size is virtual capacity, not immediate consumption. Guest RAM
  may be demand-backed, but the VM sees a fixed ceiling for each launch.
- Do not let VM launchers modify host boot, partition, CPU-core, GPU, bridge,
  or firewall policy.

## macOS boundary

The verified macOS profile remains Sequoia on a sparse 512 GiB qcow2 with a
16 GiB launch ceiling, OpenCore, loopback-only noVNC, and no host GPU or disk
passthrough. On the reference workstation, neither NVIDIA RTX 4090 nor Intel
UHD 770 is a viable modern macOS passthrough target; the virtual framebuffer is
a stability choice.

Apple installers, SMC material, OpenCore machine identity, writable firmware
state, Apple credentials, and signing assets must remain private. Apple
licenses macOS virtualization for Apple-branded hardware, so the non-Apple KVM
profile is an unsupported interoperability experiment. The complete audited
history is in the Hackintosh repository rather than repeated here.

## Repository map

| Repository | Responsibility |
| --- | --- |
| [`kvm-qemu-workstation`](https://github.com/lachlanchen/kvm-qemu-workstation) | Common dispatcher, sanitized Windows lifecycle, build patch, guest bootstrap, architecture and lessons |
| [`hackintosh`](https://github.com/lachlanchen/hackintosh) | OpenCore/macOS-specific provenance, recovery, identity, upgrade, and Xcode boundaries |
| [`the-art-of-lazying`](https://github.com/lachlanchen/the-art-of-lazying) | Concise reusable field notes and links |

This split is intentional: share the orchestration pattern, but do not merge
the operating systems' private state or trust assumptions.
