#!/bin/sh

set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

confirmation_text="REPAIR-7050-MONTEREY-DATA"
mode=${1:-audit}
if [ "$#" -gt 0 ]; then
  shift
fi
container=""
data_volume=""
confirmation=""

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  /bin/cat <<'USAGE'
Usage in macOS Recovery Terminal:
  /bin/sh repair-optiplex-7050-apfs-from-recovery.sh audit \
    --container diskN --data diskNsN

  /bin/sh repair-optiplex-7050-apfs-from-recovery.sh repair \
    --container diskN --data diskNsN \
    --confirm REPAIR-7050-MONTEREY-DATA

Discover identifiers on every Recovery boot; disk numbers can change:
  /usr/sbin/diskutil list
  /usr/sbin/diskutil apfs listVolumeGroups

The script never erases, repartitions, force-unmounts, or changes EFI. Repair
mode unmounts the selected APFS container normally, repairs only the selected
Data volume, verifies it, and mounts the container again.
USAGE
  exit 0
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --container)
      [ "$#" -ge 2 ] || fail "--container requires a disk identifier"
      container=$2
      shift 2
      ;;
    --data)
      [ "$#" -ge 2 ] || fail "--data requires a disk identifier"
      data_volume=$2
      shift 2
      ;;
    --confirm)
      [ "$#" -ge 2 ] || fail "--confirm requires a value"
      confirmation=$2
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *) fail "unknown argument: $1" ;;
  esac
done

case "$mode" in
  audit|repair) ;;
  -h|--help) usage ;;
  *) fail "mode must be audit or repair" ;;
esac

for executable in \
  /bin/cat \
  /bin/date \
  /bin/df \
  /bin/mkdir \
  /bin/rm \
  /usr/bin/awk \
  /usr/bin/grep \
  /usr/bin/id \
  /usr/bin/sed \
  /usr/bin/tee \
  /usr/sbin/diskutil; do
  [ -x "$executable" ] || fail "Recovery command is unavailable: $executable"
done

printf '%s\n' "$container" | /usr/bin/grep -Eq '^disk[0-9]+$' ||
  fail "--container must look like diskN"
printf '%s\n' "$data_volume" | /usr/bin/grep -Eq '^disk[0-9]+s[0-9]+$' ||
  fail "--data must look like diskNsN"

work_dir="/tmp/optiplex-7050-apfs-repair.$$"
/bin/mkdir -m 700 "$work_dir"
trap '/bin/rm -rf "$work_dir"' 0 1 2 15
log_file="/tmp/optiplex-7050-apfs-repair-$(/bin/date +%Y%m%d-%H%M%S).log"
apfs_before="$work_dir/apfs-before.txt"

/usr/sbin/diskutil apfs list "$container" > "$apfs_before" 2>&1 ||
  fail "APFS container is unavailable: $container"
/usr/sbin/diskutil info "$data_volume" > "$work_dir/data-info.txt" 2>&1 ||
  fail "Data volume is unavailable: $data_volume"

/usr/bin/grep -Eq "APFS Container:[[:space:]]+$container([[:space:]]|$)" \
  "$work_dir/data-info.txt" ||
  fail "the selected Data volume does not belong to $container"
/usr/bin/awk -v device="$data_volume" '
  index($0, "APFS Volume Disk (Role):") &&
  index($0, device " (Data)") { found = 1 }
  END { exit !found }
' "$apfs_before" || fail "the selected APFS volume does not have the Data role"

root_device=$(/bin/df / | /usr/bin/awk 'NR == 2 { sub("/dev/", "", $1); print $1 }')
case "$root_device" in
  "$container"|"$container"s*)
    fail "the selected container is hosting the current root; boot Recovery first"
    ;;
esac

{
  printf 'time=%s\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S%z')"
  printf 'mode=%s\n' "$mode"
  printf 'recovery_root_device=%s\n' "${root_device:-unknown}"
  printf 'container=%s\n' "$container"
  printf 'data_volume=%s\n' "$data_volume"
  printf '\n--- APFS before ---\n'
  /bin/cat "$apfs_before"
  printf '\n--- Data volume info ---\n'
  /bin/cat "$work_dir/data-info.txt"
} | /usr/bin/tee "$log_file"

if [ "$mode" = audit ]; then
  printf '\nAudit only. No volume was unmounted or repaired.\n'
  printf 'Log: %s\n' "$log_file"
  exit 0
fi

[ "$(/usr/bin/id -u)" -eq 0 ] || fail "repair mode must run as Recovery root"
[ "$confirmation" = "$confirmation_text" ] ||
  fail "repair requires literal confirmation $confirmation_text"

run_logged() {
  step_output="$work_dir/step-output.txt"
  if "$@" > "$step_output" 2>&1; then
    step_status=0
  else
    step_status=$?
  fi
  /usr/bin/tee -a "$log_file" < "$step_output"
  return "$step_status"
}

printf '\n--- Normal container unmount ---\n' | /usr/bin/tee -a "$log_file"
run_logged /usr/sbin/diskutil unmountDisk "$container" ||
  fail "normal unmount failed; close Disk Utility windows and retry (force is not used)"

printf '\n--- Data volume repair ---\n' | /usr/bin/tee -a "$log_file"
if ! run_logged /usr/sbin/diskutil repairVolume "$data_volume"; then
  printf 'Repair failed; the container is intentionally left unmounted.\n' | \
    /usr/bin/tee -a "$log_file" >&2
  exit 2
fi

printf '\n--- Post-repair verification ---\n' | /usr/bin/tee -a "$log_file"
if ! run_logged /usr/sbin/diskutil verifyVolume "$data_volume"; then
  printf 'Post-repair verification failed; the container is left unmounted.\n' | \
    /usr/bin/tee -a "$log_file" >&2
  exit 3
fi

printf '\n--- Remount ---\n' | /usr/bin/tee -a "$log_file"
run_logged /usr/sbin/diskutil mountDisk "$container" ||
  fail "repair passed but the container did not remount; reboot or mount it in Disk Utility"

printf '\n--- APFS after ---\n' | /usr/bin/tee -a "$log_file"
run_logged /usr/sbin/diskutil apfs list "$container"
printf '\nRepair and verification completed.\n'
printf 'Log: %s\n' "$log_file"
