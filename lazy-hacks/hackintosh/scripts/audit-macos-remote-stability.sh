#!/bin/bash

set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

hours="${1:-12}"
case "$hours" in
  '' | *[!0-9]*) printf 'error: hours must be an integer\n' >&2; exit 2 ;;
esac
if [ "$hours" -lt 1 ] || [ "$hours" -gt 168 ]; then
  printf 'error: hours must be between 1 and 168\n' >&2
  exit 2
fi

section() {
  printf '\n=== %s ===\n' "$1"
}

run_with_timeout() {
  local seconds="$1"
  shift

  perl -e '
    use strict;
    use warnings;
    my $seconds = shift @ARGV;
    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
      exec @ARGV;
      exit 127;
    }
    $SIG{ALRM} = sub {
      kill "TERM", $pid;
      select undef, undef, undef, 0.5;
      kill "KILL", $pid;
      waitpid $pid, 0;
      exit 124;
    };
    alarm $seconds;
    waitpid $pid, 0;
    my $status = $?;
    alarm 0;
    exit 128 + ($status & 127) if $status & 127;
    exit $status >> 8;
  ' "$seconds" "$@"
}

section "identity"
date
sw_vers
uptime
printf 'console_user=%s\n' "$(stat -f '%Su' /dev/console)"
printf 'root_audit=%s\n' "$([ "$(id -u)" -eq 0 ] && printf yes || printf no)"

section "memory and CPU"
memory_pressure 2>/dev/null | tail -n 10 || true
sysctl vm.swapusage
ps -axo pid=,user=,%cpu=,%mem=,etime=,command= |
  sort -k3 -nr |
  head -n 25 ||
  true

section "APFS and free space"
df -h / /System/Volumes/Data 2>/dev/null || df -h /
diskutil apfs list
tmutil listlocalsnapshots / 2>&1 || true
diskutil apfs listSnapshots / 2>&1 || true

section "power"
pmset -g custom
pmset -g assertions

section "display and remote services"
system_profiler SPDisplaysDataType 2>/dev/null || true
ps -axo uid=,user=,pid=,%cpu=,%mem=,etime=,command= |
  awk '
    /WindowServer|UURemote(Service|Server)|screensharingd/ &&
    $0 !~ /awk/ {
      print
    }
  '
lsof -nP -iTCP:22 -sTCP:LISTEN 2>/dev/null || true
lsof -nP -iTCP:5900 -sTCP:LISTEN 2>/dev/null || true

section "Hackintosh extensions"
kmutil showloaded 2>/dev/null |
  grep -Ei \
    'Lilu|WhateverGreen|AppleALC|IntelMausi|NVMeFix|RestrictEvents|AppleIntel(SKL|KBL)Graphics' ||
  true
nvram boot-args 2>/dev/null || true
ioreg -l -w0 -r -c AppleIntelFramebufferController 2>/dev/null |
  grep -E \
    '"AAPL,ig-platform-id"|"device-id"|"model"|"IOName"|"IOPowerManagement"' |
  head -n 80 ||
  true

section "software update state"
defaults read /Library/Preferences/com.apple.SoftwareUpdate 2>/dev/null || true
ps -axo pid=,user=,%cpu=,%mem=,etime=,command= |
  awk '
    /softwareupdated|softwareupdate / && $0 !~ /awk/ {
      print
    }
  '
du -shx /System/Volumes/Update /Library/Updates 2>/dev/null || true
diskutil info /System/Volumes/Update 2>/dev/null |
  grep -E 'Device Identifier|Volume Name|Volume Used Space' ||
  true

section "recent diagnostic reports"
find \
  /Library/Logs/DiagnosticReports \
  /var/root/Library/Logs/DiagnosticReports \
  /Users/*/Library/Logs/DiagnosticReports \
  -type f \
  -mtime -7 \
  \( \
    -iname '*panic*' -o \
    -iname '*hang*' -o \
    -iname '*spin*' -o \
    -iname '*WindowServer*' -o \
    -iname '*UURemote*' \
  \) \
  -print 2>/dev/null |
  tail -n 120 ||
  true

section "boot and power history"
last reboot shutdown | head -n 30 || true
pmset -g log 2>/dev/null |
  grep -Ei 'sleep|wake|shutdown|failure|panic|darkwake' |
  tail -n 160 ||
  true

if [ "$(id -u)" -ne 0 ]; then
  section "privileged log notice"
  printf 'Run with sudo to include protected unified-log evidence.\n'
  exit 0
fi

section "live storage errors"
storage_sample=$(mktemp "${TMPDIR:-/tmp}/macos-storage-errors.XXXXXX")
trap 'rm -f "$storage_sample"' EXIT
/usr/bin/log stream \
  --style compact \
  --level debug \
  --timeout 5 \
  --predicate \
  'process == "kernel" AND
   (eventMessage CONTAINS[c] "AbortCommands" OR
    eventMessage CONTAINS[c] "I/O error")' \
  > "$storage_sample" \
  2>/dev/null ||
  true
storage_error_count=$(
  awk '
    /^20[0-9][0-9]-/ && /kernel\[/ && /AbortCommands|I\/O error/ {
      count++
    }
    END {
      print count + 0
    }
  ' "$storage_sample"
)
printf 'storage_errors_in_5_seconds=%s\n' "$storage_error_count"
awk '
  /^20[0-9][0-9]-/ && /kernel\[/ && /AbortCommands|I\/O error/ {
    print
  }
' "$storage_sample" |
  tail -n 20
rm -f "$storage_sample"
trap - EXIT

section "kernel shutdown, watchdog, framebuffer, GPU, and memory events"
set +e
run_with_timeout 20 /usr/bin/log show \
  --last "${hours}h" \
  --style compact \
  --predicate \
  'process == "kernel" AND
   (eventMessage CONTAINS[c] "shutdown cause" OR
    eventMessage CONTAINS[c] "userspace watchdog timeout" OR
    eventMessage CONTAINS[c] "TxnHang" OR
    eventMessage CONTAINS[c] "Fake VBL" OR
    eventMessage CONTAINS[c] "Skipped flip" OR
    eventMessage CONTAINS[c] "GPU Restart" OR
    eventMessage CONTAINS[c] "GPU panic" OR
    eventMessage CONTAINS[c] "memory pressure")' \
  2>/dev/null |
  tail -n 500
log_status=${PIPESTATUS[0]}
set -e
if [ "$log_status" -eq 124 ]; then
  printf '(unified-log query stopped at the 20-second safety limit)\n'
elif [ "$log_status" -ne 0 ]; then
  printf '(unified-log query failed with status %s)\n' "$log_status"
fi
