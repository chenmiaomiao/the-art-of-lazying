# Safely Re-enable a Second NVIDIA GPU After Freeze Troubleshooting

Reintroducing a GPU is most useful when it is treated as a controlled A/B test,
not as a collection of simultaneous “fixes.” Keep the known-stable CPU, BIOS,
kernel, display, and remote-desktop state unchanged; add only the second GPU;
then validate in stages with an immediate rollback available.

This procedure was verified on Ubuntu 24.04 with an Intel i9-14900K and two RTX
4090 D cards. The second card was bound live without rebooting and passed both
isolated and dual-GPU CUDA tests.

## Decide what the old evidence actually proves

A freeze while a GPU is installed does not prove the GPU caused it. Build a
timeline around the **first** fatal event:

- NVIDIA Xid, `RmInitAdapter`, fallen-off-bus, GPU reset, or AER on the GPU's
  actual root port supports a GPU/slot/power diagnosis.
- A kernel NULL dereference or machine check first appearing on a CPU, with no
  preceding GPU error, supports CPU/platform/RAM investigation.
- A journal that simply ends proves a hard lock or reset but not its cause.
- A userspace CUDA OOM or segmentation fault is not automatically a hardware
  failure.

Intel documents Vmin Shift instability in affected 13th/14th-generation
desktop processors and recommends Intel Default Settings plus current BIOS
microcode:

- <https://www.intel.com/content/www/us/en/support/articles/000102331/processors.html>
- <https://community.intel.com/t5/Blogs/Tech-Innovation/Client/Intel-Core-13th-and-14th-Gen-Desktop-Instability-Root-Cause/post/1638681/highlight/true>
- <https://community.intel.com/t5/Mobile-and-Desktop-Processors/Intel-Core-13th-and-14th-Gen-Vmin-Shift-Instabilty-Update-New/m-p/1686948>

Updated firmware mitigates unsafe behavior; it cannot prove that a particular
CPU, RAM kit, motherboard, slot, cable, PSU, or GPU is healthy. Preserve any
CPU-offlining policy that produced the current stable baseline while testing
the GPU separately.

## Record the baseline

```bash
date --iso-8601=seconds
uname -r
cat /sys/devices/system/cpu/online
cat /sys/devices/system/cpu/offline
nvidia-smi --query-gpu=index,pci.bus_id,name,driver_version,pstate,\
temperature.gpu,power.draw,power.limit,memory.used,utilization.gpu \
  --format=csv
lspci -tv
journalctl -b -k --no-pager | rg -i \
  'NVRM|Xid|AER|MCE|hardware error|lockup|watchdog|fallen off|RmInitAdapter'
```

Map each GPU to its own upstream root port. Do not attribute an NVMe root-port
AER event to a GPU merely because both are PCIe devices.

## Use reversible PCI binding

A robust disable helper should verify the expected vendor/device IDs before
touching a fixed PCI BDF. Disabling consists of setting `driver_override` to
`none` and unbinding the audio function before the VGA function. Enabling
clears the override, probes VGA, then probes audio.

One subtle sysfs bug matters here:

```bash
# Wrong: this performs a zero-byte write, so sysfs receives nothing.
printf '' > "$device/driver_override"

# Correct: the kernel strips the newline and clears the override.
printf '\n' > "$device/driver_override"
```

Verify binding before running CUDA:

```bash
lspci -nnk -s SECOND_GPU_BDF
lspci -nnk -s SECOND_AUDIO_BDF
nvidia-smi -L
```

Keep a one-command rollback such as a `Type=oneshot`, `RemainAfterExit=yes`
service whose start disables the fixed BDFs and whose stop enables them.

## Reduce the first-test power envelope

Two 425 W boards permit 850 W of sustained GPU board power before CPU and
transient demand. PCIe lane width does not limit auxiliary GPU power. Start
with a reversible cap appropriate for the system, for example 300 W:

```bash
sudo nvidia-smi -i 0 --power-limit=300
sudo nvidia-smi -i 1 --power-limit=300
```

Use GPU UUIDs rather than indices in persistent automation:

```bash
nvidia-smi --query-gpu=index,pci.bus_id,uuid,name,power.default_limit \
  --format=csv
sudo nvidia-smi -i GPU-UUID-HERE --power-limit=300
```

A minimal boot service can call a validated helper:

```ini
[Unit]
Description=Apply conservative NVIDIA GPU power limits
After=systemd-modules-load.service nvidia-persistenced.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nvidia-stability-power-limit apply
ExecStop=/usr/local/sbin/nvidia-stability-power-limit reset
RemainAfterExit=yes
TimeoutStartSec=45
TimeoutStopSec=45

[Install]
WantedBy=multi-user.target
```

The helper should wait only for a bounded startup interval, skip absent cards
safely, and restore each board's verified default on `reset`. Reapply the
service after any live NVIDIA module reload because a driver reload resets
runtime power limits.

## Test in stages

### 1. Idle initialization

Check temperature, memory, power, audio routing, and the kernel journal before
allocating VRAM. A headless NVIDIA card may log `Cannot find any crtc or
sizes`; this is expected when it has no connected display.

### 2. Second GPU only

Select the physical second card before Python starts:

```bash
CUDA_VISIBLE_DEVICES=1 python gpu_test.py
```

The test should:

1. allocate VRAM in moderate blocks;
2. fill each block with a known byte value;
3. verify minimum and maximum without creating another multi-gigabyte
   comparison tensor;
4. release the pattern buffers;
5. run bounded FP16 matrix multiplication for 10–15 seconds;
6. synchronize and exit.

While it runs, take one telemetry snapshot and inspect link speed:

```bash
nvidia-smi --query-gpu=index,pstate,temperature.gpu,power.draw,power.limit,\
memory.used,utilization.gpu --format=csv
cat /sys/bus/pci/devices/SECOND_GPU_BDF/current_link_speed
cat /sys/bus/pci/devices/SECOND_GPU_BDF/current_link_width
```

It is normal for a PCIe link to idle at 2.5 GT/s and rise under load. A card in
an x4-wired slot remains x4; that affects transfer bandwidth, not CUDA
correctness.

### 3. Short dual-GPU test

Only after the isolated test passes, run a short concurrent workload with both
cards still power-capped. This exercises simultaneous current draw without
jumping directly to unrestricted board limits.

Peer access may be false when the cards traverse different PCIe host bridges.
That reduces direct transfer efficiency but is not evidence of bad hardware.

## Audit after load

```bash
journalctl -b -k --since '15 minutes ago' --no-pager | rg -i \
  'NVRM|Xid|AER|hardware error|MCE|lockup|watchdog|fallen off|RmInitAdapter'

for dev in GPU_BDF GPU_ROOT_PORT_BDF; do
  for counter in aer_dev_correctable aer_dev_nonfatal aer_dev_fatal; do
    file="/sys/bus/pci/devices/$dev/$counter"
    [ -r "$file" ] && { printf '%s %s\n' "$dev" "$counter"; cat "$file"; }
  done
done

nvidia-smi -q | rg -i -A 8 \
  'Replays Since Reset|Remapped Rows|GPU Recovery Action'
```

Pass criteria are not merely “Python exited zero.” Require no new Xid, GPU
reset, AER, replay, row-remap, disappearance, or thermal runaway.

## Interpret an NVIDIA large-page fallback correctly

On a long-uptime workstation, NVIDIA may report:

```text
Allocation failed with big page size, retrying with default page size
```

If the retry succeeds, CUDA finishes, substantial `MemAvailable` remains, and
there is no OOM kill, Xid, AER, replay, or remapped row, this points to host
physical-memory fragmentation rather than failed GPU VRAM. Confirm it:

```bash
free -h
cat /proc/buddyinfo
journalctl -b -k --since '10 minutes ago' --no-pager | rg -i 'oom|NVRM|Xid'
```

Do not force `swapoff -a` or manual memory compaction over a fragile remote
session. A planned reboot naturally clears stale swap and fragmentation.

## Remote audio can imitate hardware noise

Before blaming a GPU reload for breathing, pumping, or hiss, inspect PipeWire:

```bash
wpctl status
```

A remote-control client may be actively capturing a webcam microphone even
when no media app is playing. Audio capture overruns under heavy CPU load can
also produce audible artifacts. Confirm the stream and input source before
changing GPU HDMI audio drivers.

## Rollback

Keep these operations independent:

- disable only the second GPU with the reversible PCI-binding service;
- disable the power-limit service to restore verified board defaults;
- leave the CPU baseline untouched until enough stable runtime has accumulated.

After any future freeze, collect the previous boot before changing policy:

```bash
journalctl -b -1 -k --no-pager | rg -i \
  'NVRM|Xid|AER|MCE|hardware error|NULL pointer|lockup|watchdog|oom'
```

Short tests establish a clean baseline, not long-term proof. Several days of
normal mixed use provide the meaningful comparison.
