# Raspberry Pi SD-Card I/O Failure: Temporary Apt Recovery

This note is for a Raspberry Pi where `ldconfig` exits with `Bus error`, package
configuration fails, and the kernel reports SD-card I/O errors.

This procedure does **not** repair a bad sector or make the card trustworthy.
The preferred recovery is to stop writes, image the card, and replace it. The
live-mutation steps near the end are a last resort for making `apt` usable long
enough to back up or migrate the system.

## Preferred Recovery: Image And Replace

If the Pi still responds:

1. Stop broad upgrades and other write-heavy services.
2. Save application data and configuration to another device.
3. Shut down cleanly if the system can still do so.
4. Remove the card and attach it read-only to a healthy machine.
5. Image the failing card with a recovery tool such as GNU `ddrescue`.
6. Work on the image or a new card, not the only copy of the failing media.
7. Replace the card even if the immediate package error later disappears.

Do not run `fsck` on the only source before imaging it. Do not mount the failing
filesystem read-write on the recovery machine.

An image-to-file pass avoids writing to the source, but verify the source device
and destination volume before running it:

```bash
sudo ddrescue -n /dev/<source-card> /recovery-volume/pi-card.img \
  /recovery-volume/pi-card.map
sudo ddrescue -d -r3 /dev/<source-card> /recovery-volume/pi-card.img \
  /recovery-volume/pi-card.map
```

The destination must have enough free space for the full card image. Keep the
map file so a later pass can resume. Restoring an image to replacement media is
destructive to that destination and is intentionally outside this live-recovery
note.

## Confirm The Failure Mode

Stop if the only evidence is an `apt` error. First inspect package state:

```bash
sudo dpkg --audit
dpkg -l libc-bin libc6
sudo apt-get check
```

Then inspect kernel evidence:

```bash
sudo dmesg -T |
  grep -Ei 'I/O error|mmc|EXT4-fs error|Bus error|segfault|ldconfig' |
  tail -80
```

A kernel message shaped like this establishes a storage-level problem:

```text
I/O error, dev <card-device>, sector <sector-number>
```

Record the device name, sector number, timestamp, and whether more errors appear.
If errors affect multiple devices or keep moving, power down and image the card;
do not continue with live mutation.

## Back Up Small Critical Metadata

This is not a substitute for a full image. It only preserves a few files that
may help package recovery:

```bash
stamp=$(date +%Y%m%d-%H%M%S)
backup="$HOME/apt-recovery-$stamp"
mkdir -p "$backup"

sudo cp -a /etc/ld.so.conf /etc/ld.so.conf.d "$backup"/ 2>/dev/null || true
sudo cp -a /var/lib/dpkg/status "$backup/status" 2>/dev/null || true
sudo cp -a /etc/ld.so.cache "$backup/ld.so.cache.before" 2>/dev/null || true
```

Copy the backup off the card before proceeding.

## Validate Device, Partition, And Units

Only use this mapping for a kernel block-layer message whose device and sector
were recorded directly. Kernel block-layer sector numbers and the sysfs
partition `start` and `size` values below use 512-byte sectors. A sector number
reported by some other tool may use different units.

Set the three values from the evidence and partition layout:

```bash
export DISK=/dev/<card-device>
export PARTITION=/dev/<ext4-partition>
export BAD_SECTOR=<sector-number>
```

Review the layout without changing it:

```bash
sudo lsblk -o NAME,PATH,PKNAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,START
sudo fdisk -l "$DISK"
sudo blockdev --getss "$DISK"
findmnt -no SOURCE,FSTYPE,OPTIONS --target /
```

Validate the relationship and bounds before doing any arithmetic:

```bash
set -eu

: "${DISK:?set DISK first}"
: "${PARTITION:?set PARTITION first}"
: "${BAD_SECTOR:?set BAD_SECTOR first}"

case "$BAD_SECTOR" in
  ''|*[!0-9]*)
    echo 'BAD_SECTOR must be a non-negative integer' >&2
    exit 1
    ;;
esac

test -b "$DISK"
test -b "$PARTITION"

disk_name=$(basename -- "$DISK")
partition_name=$(basename -- "$PARTITION")
partition_parent=$(lsblk -dn -o PKNAME "$PARTITION")
partition_fstype=$(lsblk -dn -o FSTYPE "$PARTITION")

test "$partition_parent" = "$disk_name"
test "$partition_fstype" = ext4

start=$(cat "/sys/class/block/$partition_name/start")
sector_count=$(cat "/sys/class/block/$partition_name/size")
end=$((start + sector_count - 1))

if [ "$BAD_SECTOR" -lt "$start" ] || [ "$BAD_SECTOR" -gt "$end" ]; then
  echo "reported sector is outside $PARTITION ($start..$end)" >&2
  exit 1
fi

printf 'disk=%s partition=%s range=%s..%s bad_sector=%s\n' \
  "$DISK" "$PARTITION" "$start" "$end" "$BAD_SECTOR"
```

Stop if the kernel log names a different parent device, the partition is not
ext4, the sector is outside the partition, or the device identity is uncertain.

## Map The Sector Read-Only

Read the ext4 geometry:

```bash
geometry=$(
  sudo tune2fs -l "$PARTITION" 2>/dev/null |
    awk -F: '
      /Block size/  {gsub(/[[:space:]]/, "", $2); block_size=$2}
      /Block count/ {gsub(/[[:space:]]/, "", $2); block_count=$2}
      END {print block_size, block_count}
    '
)
read -r block_size block_count <<EOF
$geometry
EOF

for value in "$block_size" "$block_count"; do
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    echo 'could not read ext4 geometry' >&2
    exit 1
  fi
done

kernel_sector_bytes=512
if [ $((block_size % kernel_sector_bytes)) -ne 0 ]; then
  echo 'ext4 block size is not divisible by 512' >&2
  exit 1
fi

sectors_per_block=$((block_size / kernel_sector_bytes))
relative_sector=$((BAD_SECTOR - start))
fs_block=$((relative_sector / sectors_per_block))

if [ "$fs_block" -lt 0 ] || [ "$fs_block" -ge "$block_count" ]; then
  echo 'calculated ext4 block is outside the filesystem' >&2
  exit 1
fi

printf 'block_size=%s block_count=%s fs_block=%s\n' \
  "$block_size" "$block_count" "$fs_block"
```

Ask `debugfs` which inode owns the calculated block:

```bash
sudo debugfs -R "icheck $fs_block" "$PARTITION"
sudo debugfs -R "ncheck <inode-from-icheck>" "$PARTITION"
```

Continue only when all of these are true:

- `icheck` returns exactly one inode.
- `ncheck` returns exactly one plausible regular-file path.
- The inode and path agree with `stat`.
- `findmnt --target` confirms that path lives on `PARTITION`.
- The block is file data, not free space, filesystem metadata, a directory, or
  the journal.

For example:

```bash
bad='<verified-path-from-ncheck>'
sudo stat -c 'device:inode=%d:%i type=%F path=%n' -- "$bad"
findmnt -no SOURCE,FSTYPE,OPTIONS --target "$bad"
sudo debugfs -R "stat <inode-from-icheck>" "$PARTITION"
dpkg-query -S "$bad"
```

If more than one inode or path is returned, or any check disagrees, stop. Do not
guess which file to move.

## Live Mutation Is A Last Resort

Never move the dynamic loader, `libc.so.6`, an active executable, package-manager
code, the running shell, `systemd`, filesystem metadata, or any other critical
runtime file on a live system. If the mapped inode is critical or is in use,
shut down and recover from the image or an offline mount.

Check whether the candidate is in use:

```bash
sudo fuser -v -- "$bad"
```

Proceed only for a non-critical, package-owned regular file when external
imaging is not currently possible and temporary package recovery is worth the
risk.

### Keep The Quarantine On The Same Filesystem

A same-filesystem `mv` is a metadata rename and preserves the inode and its
allocated blocks. A cross-filesystem `mv` copies and unlinks the file, which can
free the suspect block for reuse.

Create an adjacent quarantine and verify both paths resolve to the same mounted
filesystem before moving anything:

```bash
bad='<verified-non-critical-path>'
bad_directory=$(dirname -- "$bad")
quarantine="$bad_directory/.io-error-quarantine"
stamp=$(date +%Y%m%d-%H%M%S)

sudo mkdir -p -- "$quarantine"

bad_source=$(readlink -f "$(findmnt -no SOURCE --target "$bad")")
quarantine_source=$(
  readlink -f "$(findmnt -no SOURCE --target "$quarantine")"
)

if [ "$bad_source" != "$quarantine_source" ]; then
  echo 'quarantine is on a different filesystem; refusing to move' >&2
  exit 1
fi

before_inode=$(sudo stat -c '%d:%i' -- "$bad")
destination="$quarantine/$(basename -- "$bad").io-error-$stamp"

printf 'source filesystem=%s inode=%s destination=%s\n' \
  "$bad_source" "$before_inode" "$destination"
```

Recheck the printed values. Only then perform the rename:

```bash
sudo mv -- "$bad" "$destination"
after_inode=$(sudo stat -c '%d:%i' -- "$destination")

if [ "$before_inode" != "$after_inode" ]; then
  echo 'inode changed unexpectedly; stop recovery work' >&2
  exit 1
fi

sync
```

Do not delete the quarantined inode. Keeping it allocated reduces the chance
that the filesystem will immediately reuse the suspect data block, but it does
not mark the physical sector bad and is not a media repair.

## Restore Package Consistency

Record the owning package from `dpkg-query -S`, then replace
`<owning-package>` below. First confirm that `ldconfig` can scan the remaining
libraries:

```bash
sudo /sbin/ldconfig
sudo dpkg --configure libc-bin
sudo dpkg --configure -a
sudo apt-get check
```

Preview the reinstall and read the proposed actions:

```bash
sudo apt-get -s install --reinstall <owning-package>
```

If the preview only repairs the intended package, run it without automatic
confirmation:

```bash
sudo apt-get install --reinstall <owning-package>
sudo /sbin/ldconfig
sudo dpkg --audit
sudo apt-get check
```

Confirm the restored path is a new inode while the quarantined inode remains:

```bash
sudo stat -c 'restored=%d:%i %n' -- "$bad"
sudo stat -c 'quarantined=%d:%i %n' -- "$destination"
```

Stop if any new I/O error appears. Do not follow this with a broad
`apt upgrade`.

## After Temporary Recovery

Use the short working window to:

1. Copy application data and configuration off the Pi.
2. Capture package and service inventories.
3. Image the card if no image exists yet.
4. Build and test a replacement card.
5. Retire the failing card.

After cloning, run filesystem checks only on an image copy or replacement media.
Repeated `mmc` or ext4 I/O errors mean the original card is no longer suitable
for an always-on router.

For the related router workflow, see
[Raspberry Pi Wi-Fi To LAN Router](./pi-wifi-to-lan-router.md).
