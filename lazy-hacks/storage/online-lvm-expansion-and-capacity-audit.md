# Online LVM Expansion and Safe Capacity Audit

This guide records a successful Ubuntu workstation expansion in which two
mounted ext4 filesystems were each enlarged by roughly 465 GiB without a
reboot. It also records the follow-up capacity audit and a conservative cache
cleanup. Hostnames, usernames, disk serial numbers, private repositories, and
private paths are intentionally omitted.

The central rule is simple:

> Add capacity only from a verified blank region on the same physical disk as
> the existing non-redundant LVM volume. Back up metadata first, never move an
> existing partition boundary online, and never mistake an unmounted
> filesystem for unused space.

## Outcome

The online expansion produced these approximate results:

| Filesystem | Before | After expansion | After safe cleanup |
| --- | ---: | ---: | ---: |
| Home | 1.4 TiB, 101 GiB free, 93% used | 1.8 TiB, 539 GiB free, 70% used | 563 GiB free, 68% used |
| Projects | 2.7 TiB, 217 GiB free, 92% used | 3.2 TiB, 655 GiB free, 79% used | 658 GiB free, 79% used |

The cleanup physically recovered approximately:

```text
Home:     25,800,323,072 bytes  (~24.0 GiB)
Projects:  3,038,687,232 bytes  (~2.83 GiB)
Combined: 28,839,010,304 bytes  (~26.9 GiB)
```

No installed Conda environment, model cache, coding-agent session, project
dataset, build output, browser profile, or Downloads file was removed. One uv
cache was deliberately left untouched because a running service held its
cache lock.

## 1. Understand the failure domain

A linear LVM logical volume has no redundancy. If it spans two physical disks,
failure of either disk can make the whole filesystem unavailable. Prefer this
order when adding space:

1. Unallocated or verified blank space on the same disk already backing the
   volume group.
2. A separate filesystem for disposable caches or generated outputs.
3. Another physical disk only when the larger failure domain is understood and
   backed up.

In this case:

- Home already used three roughly 465 GiB LVM partitions on one NVMe disk. A
  fourth existing partition on that same disk had no filesystem or LVM
  signature and was the cleanest candidate.
- Projects already used several LVM partitions on a second NVMe disk. That disk
  had roughly 470 GiB unallocated at its tail, enough for one new aligned
  partition without moving any existing boundary.
- An unmounted 465 GiB ext4 partition was rejected because it contained a real
  Ubuntu installation.
- Blank-looking partitions on another NVMe disk were rejected because the
  kernel continued to report correctable PCIe AER `RxErr` events on that
  device's path.

Adding more capacity to a disk already required by a volume does not add a new
disk dependency. Adding a suspect second disk does.

## 2. Inventory before changing anything

Use stable identity, filesystem, partition, and LVM views together:

```bash
lsblk -e7 -o NAME,PATH,TYPE,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS,MODEL,SERIAL
df -hT
findmnt --real --output SOURCE,TARGET,FSTYPE,OPTIONS

sudo pvs --units g -o pv_name,pv_size,pv_free,vg_name,pv_uuid
sudo vgs --units g -o vg_name,vg_size,vg_free,pv_count,lv_count,vg_attr
sudo lvs --units g -a \
  -o lv_path,vg_name,lv_name,lv_size,lv_attr,devices
```

Inspect the exact free sectors on each candidate disk:

```bash
sudo parted -s /dev/nvmeXnY unit s print free
sudo sgdisk -v /dev/nvmeXnY
```

For an existing candidate partition, require all of these signs:

```bash
candidate_partition=/dev/disk/by-id/REPLACE_WITH_CANDIDATE_PARTITION
sudo wipefs --no-act "$candidate_partition"
sudo blkid "$candidate_partition"
lsblk -o NAME,PATH,SIZE,FSTYPE,UUID,MOUNTPOINTS \
  "$candidate_partition"
```

Expected for a blank candidate:

- `wipefs --no-act` prints no signature;
- `blkid` prints no filesystem type;
- no mountpoint exists;
- no `/etc/fstab` or systemd mount reference exists; and
- it is not part of any current VG.

Do not infer that a partition is empty merely because it is unmounted. A
read-only metadata inspection can reveal an old operating system:

```bash
candidate_device=/dev/REPLACE_WITH_CANDIDATE_DEVICE
sudo tune2fs -l "$candidate_device" |
  grep -E 'Filesystem UUID|Last mounted on|Filesystem state|Last mount time'
sudo debugfs -R 'ls -p /' "$candidate_device"
sudo debugfs -R 'cat /usr/lib/os-release' "$candidate_device"
```

## 3. Check hardware-error evidence

Before extending a non-redundant volume, inspect the current boot for storage
and PCIe errors:

```bash
journalctl -k -b --no-pager |
  grep -Ei 'AER|PCIe Bus Error|RxErr|nvme.*(error|reset|timeout|abort)|I/O error'
```

Map root ports to current NVMe controllers rather than trusting old device
numbers:

```bash
lspci -Dnn -t

for nvme_controller in /sys/class/nvme/nvme*; do
  printf '%s  ' "$(basename "$nvme_controller")"
  tr -d '\n' < "$nvme_controller/model"
  printf '  '
  tr -d '\n' < "$nvme_controller/serial"
  printf '  '
  readlink -f "$nvme_controller/device"
done
```

Device names such as `nvme1n1` can change between boots. Use model, serial,
PCIe path, and `/dev/disk/by-id/` together. A correctable AER event does not
prove data loss, but repeated events are enough reason not to expand a critical
filesystem onto that path.

## 4. Back up GPT and LVM metadata

Store backups on a filesystem that is not being repartitioned:

```bash
backup_dir=/var/backups/lvm-expansion-YYYY-MM-DD
home_disk=/dev/disk/by-id/REPLACE_WITH_HOME_DISK
projects_disk=/dev/disk/by-id/REPLACE_WITH_PROJECTS_DISK
home_vg=REPLACE_WITH_HOME_VG
projects_vg=REPLACE_WITH_PROJECTS_VG
sudo install -d -m 0700 "$backup_dir"

sudo sgdisk --backup="$backup_dir/home-disk-before.gpt" \
  "$home_disk"
sudo sgdisk --backup="$backup_dir/projects-disk-before.gpt" \
  "$projects_disk"

sudo vgcfgbackup -f "$backup_dir/home-vg-before.conf" "$home_vg"
sudo vgcfgbackup -f "$backup_dir/projects-vg-before.conf" "$projects_vg"
```

Confirm that every file exists and is non-empty before proceeding:

```bash
sudo ls -lh "$backup_dir"
```

These files do not replace a data backup. They preserve partition-table and
LVM metadata needed for structural recovery.

## 5. Add an existing blank partition to Home

Mark only the verified candidate partition as LVM. Replace all placeholders
with values from the immediate preflight:

```bash
home_disk=/dev/disk/by-id/REPLACE_WITH_HOME_DISK
home_pv=/dev/disk/by-id/REPLACE_WITH_HOME_CANDIDATE_PARTITION
home_partition_number=REPLACE_WITH_NUMBER
home_vg=REPLACE_WITH_HOME_VG
home_lv=/dev/REPLACE_WITH_HOME_VG/REPLACE_WITH_HOME_LV

sudo parted -s "$home_disk" set "$home_partition_number" lvm on
sudo udevadm settle
sudo wipefs --no-act "$home_pv"

sudo pvcreate "$home_pv"
sudo vgextend "$home_vg" "$home_pv"
sudo vgs "$home_vg" --units g \
  -o vg_name,vg_size,vg_free,pv_count,lv_count
```

When preflight confirms that the VG previously had zero free extents and the
new PV is the only free space, consume that new capacity and grow ext4 online:

```bash
sudo lvextend -r -l +100%FREE "$home_lv"
```

If the VG already had unrelated free extents, specify an exact increment such
as `-L +465G` instead of `+100%FREE`.

## 6. Create a new Projects partition in tail free space

Adding a partition at the unallocated tail is materially safer than moving or
shrinking an existing partition. Obtain exact sectors immediately before the
change:

```bash
projects_disk=/dev/disk/by-id/REPLACE_WITH_PROJECTS_DISK
sudo parted -s "$projects_disk" unit s print free
```

Set task-specific sector values only after checking that:

- the start equals the first sector of the tail free region;
- the start is properly aligned;
- the end is inside that same free region;
- the requested size is correct; and
- no existing partition start or end will change.

```bash
projects_start_sector=REPLACE_WITH_VERIFIED_START
projects_end_sector=REPLACE_WITH_VERIFIED_END

sudo parted -s "$projects_disk" unit s mkpart primary \
  "${projects_start_sector}s" "${projects_end_sector}s"
sudo parted -s "$projects_disk" unit s print free
```

Do not continue unless the new partition has exactly the intended boundaries
and every older boundary is unchanged. Then mark and discover it:

```bash
projects_partition_number=REPLACE_WITH_NEW_NUMBER
sudo parted -s "$projects_disk" set "$projects_partition_number" lvm on
sudo udevadm settle

lsblk -o NAME,PATH,TYPE,SIZE,FSTYPE,MOUNTPOINTS "$projects_disk"
```

Resolve the new stable partition path from `/dev/disk/by-id/`, verify that it
has no signature, and extend the VG:

```bash
projects_pv=/dev/disk/by-id/REPLACE_WITH_PROJECTS_NEW_PARTITION
projects_vg=REPLACE_WITH_PROJECTS_VG
projects_lv=/dev/REPLACE_WITH_PROJECTS_VG/REPLACE_WITH_PROJECTS_LV

sudo wipefs --no-act "$projects_pv"
sudo pvcreate "$projects_pv"
sudo vgextend "$projects_vg" "$projects_pv"
sudo lvextend -r -l +100%FREE "$projects_lv"
```

The successful case added one 465 GiB partition while leaving approximately
5 GiB of tail space unused. No existing partition was moved or resized.

## 7. Verify immediately after expansion

Check capacity and mapping:

```bash
projects_mount=/replace/with/projects-mount
df -hT /home "$projects_mount"

sudo pvs --units g -o pv_name,pv_size,pv_free,vg_name,pv_uuid
sudo vgs --units g -o vg_name,vg_size,vg_free,pv_count,lv_count,vg_attr
sudo lvs --units g \
  -o lv_path,vg_name,lv_name,lv_size,lv_attr,devices \
  "$home_vg" "$projects_vg"
```

Check structural and filesystem metadata:

```bash
sudo vgck "$home_vg" "$projects_vg"
sudo sgdisk -v "$home_disk"
sudo sgdisk -v "$projects_disk"

sudo tune2fs -l "$home_lv" |
  grep -E 'Filesystem state|Block count|Free blocks|Block size'
sudo tune2fs -l "$projects_lv" |
  grep -E 'Filesystem state|Block count|Free blocks|Block size'
```

Confirm that persistent mount UUIDs are unchanged:

```bash
sudo blkid "$home_lv" "$projects_lv"
sudo findmnt --verify --verbose --tab-file /etc/fstab
```

Finally, inspect only events since the operation began:

```bash
operation_start='YYYY-MM-DD HH:MM:SS'
journalctl -k --since "$operation_start" --no-pager |
  grep -Ei 'EXT4-fs.*(error|warning)|I/O error|Buffer I/O|nvme.*(reset|timeout|abort|error)|device-mapper.*error|AER|PCIe Bus Error'
```

In the recorded run, both filesystems reported `clean`, `vgck` was silent,
GPT verification found no structural problem, and no target-disk I/O or ext4
error occurred. The known-suspect unused NVMe path logged another correctable
AER event, reinforcing the decision not to add it to either critical VG.

Create post-change backups too:

```bash
sudo sgdisk --backup="$backup_dir/home-disk-after.gpt" \
  "$home_disk"
sudo sgdisk --backup="$backup_dir/projects-disk-after.gpt" \
  "$projects_disk"
sudo vgcfgbackup -f "$backup_dir/home-vg-after.conf" "$home_vg"
sudo vgcfgbackup -f "$backup_dir/projects-vg-after.conf" "$projects_vg"
```

Because LV filesystem UUIDs and `/etc/fstab` entries remained unchanged, the
online expansion required neither an fstab edit nor a reboot.

## 8. Audit capacity without crossing mounts

Use `df` for actual filesystem pressure and `du -x` for composition:

```bash
projects_mount=/replace/with/projects-mount
df -hT /home "$projects_mount"
df -i /home "$projects_mount"

ionice -c3 nice -n 19 du -x -B1G --max-depth=1 "$HOME"
ionice -c3 nice -n 19 du -x -B1G --max-depth=1 "$projects_mount"
```

The sanitized Home inventory was dominated by:

| Category | Approximate size | Treatment |
| --- | ---: | --- |
| Conda installation and environments | 370 GiB | Preserve environments; clean only through Conda |
| User caches | 201 GiB | Inspect by owner; model caches are not generic trash |
| Two development-engine trees | 186 GiB | Preserve unless a version is confirmed obsolete |
| Coding-agent state and sessions | 106 GiB | Preserve; this is history, not a normal cache |
| Cloud-synchronized local content | 73 GiB | Use the cloud client's supported release method |
| Downloads | 52 GiB | Inspect large files and exact duplicates individually |
| Local application state | 28 GiB | Do not recursively delete |
| Android SDK/emulator state | 28 GiB | Remove only obsolete AVDs through supported tools |

Within the 201 GiB cache tree, major components included:

```text
140 GiB  Hugging Face models and datasets
 15 GiB  Whisper models
  7 GiB  pip download/build cache
  2 GiB  uv cache
```

The Projects filesystem was dominated by real datasets, media, model assets,
and generated outputs. Two visible candidates were a 169 GiB build directory
and a 34 GiB project cache, but neither was automatically deleted: generated
books, evidence, current packages, and model artifacts may be the only current
verified copy.

Inode usage was only 5-6%, so capacity rather than inode exhaustion was the
problem.

## 9. Conservative cache cleanup

Before touching any cache, check for active package operations:

```bash
ps -eo pid,stat,etimes,comm,args |
  grep -Ei 'conda|mamba|pip|npm|npx|uv' |
  grep -Ei 'install|add|remove|uninstall|update|sync|lock|cache|clean|purge' || true
```

Long-running `npm run` or `uv run` application servers are not installers, but
their cache locks must still be respected.

### Trash

Inspect before emptying:

```bash
gio trash --list
du -sh "$HOME/.local/share/Trash" \
  "${projects_mount}/.Trash-$(id -u)"
```

`gio trash --empty` may empty Trash on every currently connected volume. For a
scoped cleanup, first resolve each intended Trash root with `realpath`, verify
that `files`, `info`, and `expunged` are ordinary user-owned directories rather
than symlinks, and empty only the reviewed roots. Keep the Trash directories
themselves.

### Conda

```bash
conda clean --all --dry-run
conda clean --all --yes
```

Do not use `--force-pkgs-dirs`. The supported cleanup removed unused cached
packages and tarballs without modifying environments.

### pip

```bash
python -m pip cache info
python -m pip cache purge
```

### npm

```bash
npm cache verify
npm cache clean --force
npm cache verify
```

The `--force` warning is expected for npm's cache command; do not generalize it
to package removal commands.

### uv

```bash
uv cache clean
```

If uv reports that the cache is in use, do **not** add `--force` and do not stop
an unrelated project service merely to recover cache space. Cancel only the
waiting cleanup command and defer the cache until the owner process is
finished. Also avoid cleaning when an environment deliberately uses uv's
`symlink` link mode.

## 10. Verify cleanup by physical capacity

Record byte-accurate `df` values before and after:

```bash
df -B1 --output=source,size,used,avail,pcent,target \
  /home "$projects_mount"
```

Verify each supported cache owner:

```bash
conda clean --all --dry-run --json
python -m pip cache info
npm cache verify
du -sb "$HOME/.cache/uv"
```

The completed run ended with:

- both reviewed Trash roots empty;
- Conda reporting zero remaining removable package/tarball cache;
- pip reporting zero HTTP cache and only negligible metadata;
- npm reporting zero content-cache entries;
- active npm and uv application services still running; and
- approximately 26.9 GiB physically reclaimed across the two filesystems.

The uv cache remained about 1 GiB because its active lock was respected.

## 11. What was deliberately preserved

The cleanup did not remove:

- Conda environments;
- Hugging Face or Whisper models;
- coding-agent sessions or their backup;
- browser profiles;
- project source, data, evidence, build trees, or package outputs;
- cloud-synchronized files;
- large Downloads archives or incomplete downloads; or
- the old Ubuntu filesystem discovered during partition selection.

That restraint matters more than maximizing the number shown by `df`.

## Reusable decision rule

```text
Measure -> identify physical ownership -> inspect signatures and history
-> reject cross-disk/suspect candidates -> back up GPT and LVM metadata
-> add only blank tail/same-disk capacity -> grow online -> verify
-> clean only supported caches -> measure physical reclaim
```

If a candidate cannot pass every verification step, preserve it and choose a
different storage design.
