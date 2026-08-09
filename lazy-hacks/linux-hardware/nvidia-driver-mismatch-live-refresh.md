# Refresh an NVIDIA Driver Mismatch Without Rebooting Ubuntu

This playbook repairs a running NVIDIA kernel module that no longer matches the
installed userspace libraries. It is intended for an Intel-primary workstation
where NVIDIA is used for compute or render offload—not for a machine whose live
desktop is driven directly by NVIDIA.

The safe principle is simple:

> Never force-remove an NVIDIA module. Reload it only after proving that NVIDIA
> is not driving a display and every GPU client has released the device.

If those conditions cannot be established, rebooting remains the safer fix.

## Recognize the mismatch

A common symptom is:

```text
Failed to initialize NVML: Driver/library version mismatch
```

Compare the running and installed versions:

```bash
cat /proc/driver/nvidia/version
modinfo -F version nvidia
nvidia-smi
```

In the verified incident behind this guide:

- the machine had booted with open kernel module `595.71.05`;
- APT and DKMS later installed `595.84` and regenerated the initramfs;
- the machine was not rebooted, so the old module remained resident;
- NVML `595.84` could not communicate with kernel module `595.71.05`.

This is a software lifecycle mismatch, not by itself evidence of a defective
GPU. Repeated `nvidia-smi` attempts may fill the kernel journal with API
mismatch messages while merely reporting the same condition.

## Separate driver mismatch from hardware failure

Check the current boot for stronger GPU evidence:

```bash
journalctl -k -b --no-pager | rg -i \
  'NVRM: Xid|fallen off|RmInitAdapter|GPU fault|PCIe Bus Error'
```

Map every reported PCIe root port before blaming the GPU:

```bash
lspci -tv
lspci -s 00:01.0 -vv
```

In the verified case, there were no Xid or fallen-off-bus events. Twelve
correctable PCIe events belonged to two NVMe root ports, not either RTX card.

## Decide whether a live reload is safe

### 1. Find the boot/display GPU

```bash
for flag in /sys/bus/pci/devices/*/boot_vga; do
  [ -r "$flag" ] || continue
  [ "$(cat "$flag")" = 1 ] || continue
  device="${flag%/boot_vga}"
  printf '%s driver=' "$(basename "$device")"
  basename "$(readlink -f "$device/driver")"
done
```

Do not live-reload NVIDIA when this reports `nvidia`.

### 2. Map DRM devices and connectors

```bash
for card in /sys/class/drm/card[0-9]*; do
  [ -e "$card/device/driver" ] || continue
  printf '%s -> %s, driver=%s\n' \
    "$(basename "$card")" \
    "$(basename "$(readlink -f "$card/device")")" \
    "$(basename "$(readlink -f "$card/device/driver")")"
done

for status in /sys/class/drm/card*-*/status; do
  [ -r "$status" ] || continue
  printf '%s=' "$(basename "$(dirname "$status")")"
  cat "$status"
done
```

Refuse a live reload if an NVIDIA connector is `connected`.

### 3. Find every client as root

An unprivileged `fuser` can hide GDM or another user's Xorg process. Always run
the final check with `sudo`:

```bash
sudo fuser -v /dev/nvidia* /dev/dri/card* /dev/dri/renderD*
```

Typical blockers include:

- real CUDA or rendering jobs;
- `nvidia-persistenced`;
- GDM/Xorg, even when Intel owns the monitor;
- XRDP Xorg auto-adding NVIDIA as an unused provider;
- Electron, WebKit, Wine, or synchronization GUIs;
- a health API polling `nvidia-smi` every few seconds.

Never terminate an unknown client automatically. Identify the process and
decide whether its work is disposable.

To trace a short-lived poller without adding a permanent loop:

```bash
sudo timeout 20s execsnoop-bpfcc -n nvidia-smi
```

The output includes the parent PID. Inspect it with:

```bash
ps -o pid,ppid,user,comm,args -p PARENT_PID
cat /proc/PARENT_PID/cgroup
```

## Perform a controlled live reload

First close or pause all approved clients. If GDM alone holds NVIDIA and Intel
is unquestionably the boot GPU, a maintenance window may stop and restore the
display manager. This can close the physical desktop, so run the operation from
a persistent shell such as SSH or tmux.

Stop persistence if active:

```bash
sudo systemctl stop nvidia-persistenced.service
```

Repeat the root `fuser` check. When it is empty, remove dependent modules
before the core module:

```bash
sudo modprobe -r nvidia_drm
sudo modprobe -r nvidia_uvm
sudo modprobe -r nvidia_modeset
sudo modprobe -r nvidia
```

Load the installed stack again:

```bash
sudo modprobe nvidia
sudo modprobe nvidia_modeset
sudo modprobe nvidia_drm
sudo modprobe nvidia_uvm
sudo udevadm settle --timeout=15
```

Then verify immediately:

```bash
cat /proc/driver/nvidia/version
modinfo -F version nvidia
nvidia-smi -L
```

If any unload command reports that a module is in use, stop. Do not use forced
`rmmod`, PCI hot-remove, or sysfs unbind against a live client.

## Make future package upgrades self-checking

A safe persistent design has three parts:

1. A root helper compares the loaded and installed versions.
2. It reloads only when Intel drives boot VGA, no NVIDIA connector is active,
   and `fuser` reports no clients.
3. An APT post-invoke hook asks a one-shot systemd service to run the helper.

The service should have no timer or retry loop:

```ini
[Unit]
Description=Safely refresh NVIDIA kernel modules after package upgrades
After=systemd-modules-load.service
ConditionPathExists=/usr/local/sbin/nvidia-live-refresh

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nvidia-live-refresh reload --if-idle
Nice=10
IOSchedulingClass=idle
```

APT hook example:

```aptconf
DPkg::Post-Invoke { "/bin/systemctl start --no-block nvidia-live-refresh.service >/dev/null 2>&1 || true"; };
```

The helper should create a pending marker and return successfully when a client
is active. A separate, explicit maintenance command can pause known local GUI
services, reload the driver, and restore them with an `EXIT` trap. It must still
refuse unknown PIDs.

This hook reconciles safe upgrades automatically; it does not promise that an
in-use GPU can be updated invisibly. A real compute job should win over driver
maintenance.

## Keep XRDP on Intel

XRDP can open a newly added NVIDIA DRM device even when its explicit render
node is Intel. In `/etc/X11/xrdp/xorg.conf`, keep the tested Intel render node
and disable automatic GPU addition:

```conf
Section "ServerFlags"
    Option "DefaultServerLayout" "X11 Server"
    Option "DontVTSwitch" "on"
    Option "AutoAddDevices" "off"
    Option "AutoAddGPU" "off"
EndSection

Section "Device"
    Identifier "Video Card (xrdpdev)"
    Driver "xrdpdev"
    Option "DRMDevice" "/dev/dri/renderD128"
    Option "DRI3" "1"
EndSection
```

Do not copy `renderD128` blindly. Confirm which render node maps to Intel:

```bash
ls -l /dev/dri/by-path
for node in /sys/class/drm/renderD*; do
  printf '%s -> %s\n' \
    "$(basename "$node")" \
    "$(basename "$(readlink -f "$node/device")")"
done
```

Back up `xorg.conf` first. The change applies to the next XRDP Xorg session; it
does not require rebooting the whole machine.

## Validate the repaired GPU

Start with status and an idle baseline:

```bash
nvidia-smi --query-gpu=index,name,driver_version,pci.bus_id,temperature.gpu,\
power.draw,memory.used,memory.total,utilization.gpu \
  --format=csv
```

The following PyTorch test checks a 4 GiB byte pattern without allocating a
second 4 GiB comparison tensor, then performs bounded FP16 matrix work:

```python
import time
import torch

assert torch.cuda.is_available()

size = 4 * 1024**3
buffer = torch.empty(size, dtype=torch.uint8, device="cuda")
buffer.fill_(0x5A)
assert int(torch.amin(buffer).item()) == 0x5A
assert int(torch.amax(buffer).item()) == 0x5A
del buffer
torch.cuda.empty_cache()

a = torch.randn((8192, 8192), device="cuda", dtype=torch.float16)
b = torch.randn((8192, 8192), device="cuda", dtype=torch.float16)
deadline = time.monotonic() + 12
result = None
while time.monotonic() < deadline:
    for _ in range(20):
        result = torch.mm(a, b)
    torch.cuda.synchronize()

assert result is not None
assert torch.isfinite(result).all().item()
```

Avoid `torch.count_nonzero(buffer != value)` on a multi-gigabyte buffer. The
comparison and reduction can allocate unexpectedly large temporary storage and
produce an ordinary userspace CUDA OOM even when the GPU is healthy.

After testing, check both telemetry and the journal:

```bash
nvidia-smi
journalctl -k --since '10 minutes ago' --no-pager | rg -i \
  'NVRM: Xid|API mismatch|fallen off|RmInitAdapter|PCIe Bus Error|GPU fault'
```

## Verified result

The source workstation completed the live transition from `595.71.05` to
`595.84` without rebooting. Its single enabled RTX 4090 D then passed:

- a 4 GiB VRAM pattern scan with minimum and maximum both `0x5A`;
- 2,507 FP16 `8192 × 8192` matrix multiplications;
- finite-output validation;
- post-test idle temperature of 33 °C;
- zero new API mismatch, Xid, fallen-off-bus, PCIe, or CUDA kernel errors.

The second GPU remained deliberately unbound, and CPU-offlining policy was not
changed. This separation matters: repair one variable, validate it, and only
then change multi-GPU topology.

The second card was later reintroduced as a separate controlled experiment.
See [Safely Re-enable a Second NVIDIA GPU After Freeze Troubleshooting](./dual-nvidia-gpu-staged-reenable.md)
for reversible PCI binding, conservative board-power limits, isolated and
dual-GPU validation, and interpretation of host-memory large-page fallbacks.

## Remaining risks

- A live reload cannot be made universally safe while arbitrary jobs use the
  GPU. Deferral is a feature, not a failure.
- Mixed old and new NVIDIA package families should be reviewed with an APT
  simulation before cleanup; do not purge them during emergency recovery.
- A driver repair does not solve unrelated memory pressure. Full swap, browser
  software rendering, emulators, and automation workers can still make a
  healthy GPU workstation appear frozen.
- The open kernel module reload does not prove that a second GPU, riser, power
  cable, or reduced-lane slot is stable. Test those separately with rollback.

## Rollback

Disable an APT hook without deleting it:

```bash
sudo mv /etc/apt/apt.conf.d/99-nvidia-live-refresh \
  /etc/apt/apt.conf.d/99-nvidia-live-refresh.disabled
```

Restore the XRDP backup and reconnect the XRDP session:

```bash
sudo cp -a /etc/X11/xrdp/xorg.conf.before-nvidia-refresh \
  /etc/X11/xrdp/xorg.conf
```

Rollback should never include forced module removal while a display or compute
client is active.
