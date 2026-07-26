# Prevent Gradle and UU Workloads from Freezing Ubuntu

## Incident

The OptiPlex-7090 froze on 2026-07-26 while UU Remote, multiple Codex sessions,
Android builds, an emulator, and browser/noVNC workspaces were active.

This was not a GPU or NVMe failure. The 21:40 `atop` sample recorded:

- 15.4 GiB RAM with only 486.7 MiB available;
- 4 GiB swap effectively 100% full;
- load average 61.47;
- a LightMind Gradle daemon using 3.8 GiB resident;
- its Kotlin compiler child using 2.5 GiB resident;
- a headless emulator using 1.4 GiB;
- UU `GameViewerServer.exe` using 1.1 GiB.

The Gradle log identified
`GlassAgent/Glass/apps/lightmind-android`, 43 builds, and the default
three-hour idle lifetime. After the last build, Gradle repeatedly saw about
0.5 GiB free but retained both Java processes. Starting the emulator pushed
the workstation into swap and I/O thrash.

Sysstat recorded 74 blocked tasks and 100% swap use. The journals contained no
i915 reset, NVMe error, or OOM kill.

## Project Fix

For a 16 GiB Android workstation:

```properties
org.gradle.jvmargs=-Xmx2048m -Dfile.encoding=UTF-8
org.gradle.daemon.idletimeout=120000
org.gradle.workers.max=4
kotlin.daemon.jvmargs=-Xmx1024m -XX:MaxMetaspaceSize=384m
```

Keep the project properties in its `gradle.properties`. Put the idle, worker,
and Kotlin defaults in `~/.gradle/gradle.properties` to cover other checkouts.

The existing 2 GiB Gradle heap was retained for Android release lint and
assembly. The fix caps the separate Kotlin process and stops both daemons two
minutes after the build becomes idle.

Verify:

```bash
./gradlew help --console=plain
./gradlew --status --console=plain
```

The new daemon log must show `idleTimeout=120000`. After two idle minutes,
`--status` should report no running Gradle daemon.

## Swap and OOM Guard

The workstation's existing `/swap.img` was expanded from 4 GiB to 12 GiB:

```bash
sudo swapoff /swap.img
sudo truncate -s 0 /swap.img
sudo fallocate -l 12G /swap.img
sudo chmod 600 /swap.img
sudo mkswap /swap.img
sudo swapon /swap.img
```

Do this only when the current swap has enough free capacity to turn off
safely. `/etc/fstab` already referenced `/swap.img`, so no mount entry changed.

Ubuntu's `systemd-oomd` was configured to act when the logged-in user consumes
90% of total swap:

```bash
sudo systemctl set-property user@1000.service ManagedOOMSwap=kill
sudo systemctl daemon-reload
oomctl dump
```

Replace `1000` with the actual desktop user's UID. This can terminate a
descendant workload under extreme pressure, but that is preferable to an
indefinitely frozen graphical session.

## UU Containment

The bridge's user service now has:

```ini
MemoryHigh=3G
MemoryMax=4G
MemorySwapMax=2G
TasksMax=1024
OOMPolicy=stop
Restart=on-failure
```

UU normally stays well below those memory limits. If Wine develops a memory or
thread leak, only the supervised relay is stopped and rebuilt.

Inspect live values:

```bash
systemctl --user show uu-remote-bridge.service \
  -p MemoryCurrent -p MemoryHigh -p MemoryMax \
  -p MemorySwapCurrent -p MemorySwapMax \
  -p TasksCurrent -p TasksMax -p OOMPolicy
```

After applying the limits, the bridge passed all source tests and its complete
270-second live verifier without a restart or GNOME RDP descriptor growth.

## Diagnosis Commands

Current pressure:

```bash
free -h
swapon --show
cat /proc/pressure/memory
cat /proc/pressure/io
oomctl dump
ps -eo pid,ppid,stat,%cpu,%mem,rss,comm,args --sort=-rss | head -30
```

Recorded incident:

```bash
atop -r /var/log/atop/atop_YYYYMMDD \
  -b HH:MM -e HH:MM -M -G -l -m
```

Keep `atop.service` and `atop-rotate.timer` enabled. Do not close large Codex,
UU, emulator, or browser sessions on size alone; use the recorder to identify
retained memory and the process ancestry first.
