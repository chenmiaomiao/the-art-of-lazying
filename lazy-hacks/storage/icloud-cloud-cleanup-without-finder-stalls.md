# Clean iCloud in the Cloud Without Finder Stalls

The future goal is to reduce **iCloud account usage**, not merely release local
Mac storage. Those are different actions and have very different consequences.

## Choose the intended operation

| Goal | Correct action | Effect |
| --- | --- | --- |
| Free Mac space but keep the cloud file | Finder → Control-click → **Remove Download** | Removes the local downloaded copy; the item remains in iCloud |
| Reduce iCloud storage | Delete the item in [iCloud Drive on iCloud.com](https://www.icloud.com/iclouddrive) | Deletes it from iCloud and every device with iCloud Drive enabled |
| Permanently erase immediately | Delete it again from **Recently Deleted** | Removes the recovery path; irreversible |

Apple documents **Remove Download** as a local-space operation:
[Work with folders and files in iCloud Drive](https://support.apple.com/guide/mac-help/work-with-folders-and-files-in-icloud-drive-mchl1a02d711/mac).

Apple also states that deleting from iCloud.com deletes the item from all
devices using iCloud Drive:
[Delete files in iCloud Drive on iCloud.com](https://support.apple.com/guide/icloud/delete-files-mm3b7fcd0c10/icloud).

## Why previous Finder work could stall

An optimized iCloud Drive contains placeholders. Recursive `du`, hashing, mass
Finder moves, or scripts that open every file can cause macOS to materialize
content or queue a very large number of sync operations. Finder then appears
stuck even though CloudDocs is processing the backlog.

For cloud-side cleanup:

- do not recursively hash `~/Library/Mobile Documents/com~apple~CloudDocs`;
- do not run broad `rm` commands inside that path;
- do not move thousands of cloud files through Finder in one operation;
- do not edit CloudDocs databases or private metadata; and
- do not use a third-party cleaner that asks for the Apple Account password.

Deleting through iCloud.com is the cleanest supported cloud-side route. It
does not require the Mac to download each selected Drive placeholder first.

## Large-first, low-stall workflow

### 1. Inventory categories

On the Mac:

```text
System Settings → Apple Account → iCloud → Manage
```

Also inspect:

- [iCloud Storage on the web](https://www.icloud.com/storage)
- [iCloud Drive on the web](https://www.icloud.com/iclouddrive)
- Photos, device backups, Messages, Mail, and app-specific storage separately

Apple's account-storage guide is:
[Manage iCloud storage](https://support.apple.com/en-us/108922).

### 2. Remove the largest known obsolete categories first

Use this order:

1. obsolete device backups;
2. abandoned app data;
3. known large iCloud Drive project exports, installers, VM images, and copied
   archives;
4. duplicate photos/videos through Photos;
5. smaller document duplicates.

Do not delete an app's whole iCloud category merely because it is large.
Export or retain anything that is not reproducible.

### 3. Work in bounded batches

On iCloud.com:

1. delete one large folder or roughly 5–20 large files;
2. wait for the web view to settle;
3. reload iCloud Drive and confirm the intended names disappeared;
4. confirm unrelated neighboring items remain;
5. check iCloud Storage again; and
6. continue with the next batch.

Small batches avoid one enormous browser/UI transaction and make recovery
obvious. A top-level folder can still represent a very large cloud deletion,
so inspect its contents before selecting it.

### 4. Keep the recovery window

Files deleted from iCloud Drive are recoverable for 30 days. Apple states that
files in Recently Deleted do not count against iCloud storage, so there is no
space-saving reason to erase them immediately.

Verify the result for several days before emptying anything:

- [Recover deleted files on iCloud.com](https://support.apple.com/guide/icloud/recover-deleted-files-mmae56ea1ca5/icloud)
- [Permanently remove deleted files](https://support.apple.com/guide/icloud/permanently-remove-deleted-files-mm9cf51c51f4/icloud)

Do not empty the Mac's Trash while relying on it or iCloud Recently Deleted as
the recovery path.

## Duplicate cleanup

### Photos and videos in Photos

Use Apple's content-aware duplicate workflow:

```text
Photos → Utilities → Duplicates → select sets → Merge
```

Apple keeps the best-quality item and relevant metadata while moving redundant
copies to Recently Deleted:
[Remove duplicate photos and videos on Mac](https://support.apple.com/guide/photos/remove-duplicates-pht5a3157c1d/mac).

Let Photos finish indexing. If **Duplicates** is absent, it may still be
analyzing the library or may not have identified duplicates.

### Ordinary iCloud Drive files

iCloud Drive has no supported cloud-side SHA-256 duplicate finder. Names and
sizes are only candidates, not proof.

For exact verification without filling or stalling the Mac's startup disk:

1. attach an external SSD with enough temporary space;
2. configure the browser's download destination to a staging folder on that
   SSD;
3. download only one bounded duplicate-candidate batch from iCloud.com;
4. compare candidates on the external SSD:

   ```bash
   shasum -a 256 "/Volumes/External/iCloud-review/file-a"
   shasum -a 256 "/Volumes/External/iCloud-review/file-b"
   ```

5. delete the redundant cloud item through iCloud.com only when hashes match
   and the preferred path is clear;
6. retain Recently Deleted during verification; and
7. remove the external staging copy after the cloud result is confirmed.

For very large folders, compare a downloaded manifest only after every file is
fully present on the external SSD. Do not hash optimized placeholders in the
live CloudDocs tree.

## If Finder is already stalled

1. Stop issuing more moves or deletions.
2. Leave the Mac awake and connected to a stable network.
3. Verify the cloud state from iCloud.com rather than repeatedly reopening the
   same Finder folder.
4. Close extra Finder windows displaying the affected tree.
5. Wait for the current batch to settle before restarting Finder.
6. Restart Finder only if the web state is stable and the local UI remains
   unresponsive:

   ```bash
   killall Finder
   ```

Restarting Finder does not cancel a cloud deletion already accepted by iCloud.
Do not kill CloudDocs processes or delete their databases as a “speed fix.”

## Completion checklist

- iCloud.com shows only the intended deletions.
- Other devices show the same surviving files.
- iCloud Storage reports the expected lower usage.
- Recently Deleted contains the removed files during the review period.
- Irreplaceable data has an independent external backup.
- The Mac's local free space is checked separately; cloud usage and local
  usage are not assumed to be the same.
