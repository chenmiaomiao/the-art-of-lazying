# Storage and Disk Cleanup

Safe workflows for recovering space without deleting the only copy of data or
turning a cloud-sync operation into an accidental cross-device deletion.

## Guides

- [Online LVM expansion and safe capacity audit](./online-lvm-expansion-and-capacity-audit.md)
  - select same-disk capacity without overwriting an unmounted operating system;
  - reject a disk path with repeated PCIe AER errors;
  - back up GPT and LVM metadata before changing partition or VG state;
  - grow mounted ext4 filesystems online without changing their UUIDs; and
  - verify and reclaim only supported caches while respecting active services.

- [Fast, safe workstation cleanup](./workstation-disk-cleanup-and-downloads-organization.md)
  - measure real filesystem pressure before acting;
  - clear package/model caches through their supported tools;
  - find exact duplicates with size bucketing and SHA-256;
  - preserve an approved project copy before removing a Downloads copy; and
  - organize the remaining Downloads entries without flattening folders.

- [Cloud-side iCloud cleanup without Finder stalls](./icloud-cloud-cleanup-without-finder-stalls.md)
  - distinguish **Remove Download** from deleting data in iCloud;
  - delete known cloud data through iCloud.com without downloading every
    placeholder to the Mac;
  - work large-first in small, verifiable batches;
  - use Apple's Photos duplicate merger; and
  - retain the 30-day recovery window while the result is checked.

## Rule

Cache cleanup may be repeatable. Personal-data deletion is not. Inventory,
preview, verify another copy, and only then delete the exact approved target.
