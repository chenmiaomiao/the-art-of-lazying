# Fast, Safe Workstation Disk Cleanup

This records the large `/home` cleanup completed on the Ubuntu workstation in
July 2026. The method favors supported cache commands, large-first inspection,
and exact-content verification. It does not treat an environment directory,
cloud placeholder, or same-named file as disposable.

## Result

The workstation's `/home` filesystem moved from critically full to:

```text
Filesystem                  Type  Size  Used Avail Use%
/dev/mapper/vg_home-lv_home ext4  1.4T  882G  421G  68%
```

`~/Downloads` moved from about `57.9 GiB` to `9.9 GiB`. The visible candidate
sizes below are apparent/report sizes and should not be added as a promise of
physical space: hard links, cache deduplication, GB/GiB units, and measurement
time can make the sum differ from `df`.

Major reviewed candidates included:

| Candidate | Reviewed amount | Action |
| --- | ---: | --- |
| Two cached Llama-3 70B variants | 183.6 GiB | Removed from the Hugging Face cache |
| Abandoned Hugging Face temporary downloads from 2024 | 87 GiB | Removed after age and path review |
| pip cache | 30.4 GB | Purged with pip |
| Conda package/tarball cache | 27.1 GB | Cleaned with `conda clean --all` after dry-run |
| npm cache | 11.8 GiB | Cleared only to reclaim space |
| uv cache | 5.9 GiB | Cleared after verifying it was disposable |
| User Trash | about 44 GiB | Emptied after inspection |
| First large Downloads duplicate pass | 38 files / about 45 GiB | Removed only after exact project copies were verified |
| Full book/video duplicate pass | 499 files / 7,415,883,531 bytes | 448 books and 51 MP4s removed after a second SHA-256 check |
| Xcode and Linux/macOS installers | about 3.87 GiB | Removed after explicit approval |

## 1. Measure before deleting

Use filesystem usage as the ground truth:

```bash
df -hT "$HOME"
du -xhd1 "$HOME" 2>/dev/null | sort -h
```

For interactive inspection:

```bash
ncdu -x "$HOME"
```

`-x` keeps the scan on the current filesystem. Do not start by recursively
deleting the largest directory. In this case `~/miniconda3` contained real
environments, while much of `~/.cache` was reproducible.

Before cleaning package caches, confirm no installer or training/download job
is active:

```bash
pgrep -af 'conda|pip|uv|npm|huggingface|python.*download' || true
```

## 2. Empty Trash only after review

List it first:

```bash
gio trash --list
```

Then, only when every item is intentionally discardable:

```bash
gio trash --empty
```

Do not use this while relying on Trash as the recovery path for an iCloud
Drive deletion. See the separate
[iCloud guide](./icloud-cloud-cleanup-without-finder-stalls.md).

## 3. Clean caches through their owners

### Hugging Face

Use the supported cache inventory:

```bash
hf cache ls
hf cache prune --dry-run
```

Remove an explicitly selected model only after the dry run:

```bash
hf cache rm model/OWNER/REPOSITORY --dry-run
hf cache rm model/OWNER/REPOSITORY --yes
```

Prune unreferenced revisions and interrupted `.incomplete` downloads:

```bash
hf cache prune --dry-run
hf cache prune --yes
```

Old releases may also leave legacy `tmp*` files. Inventory by age and size,
but do not pipe this directly to deletion:

```bash
hf_root="${HF_HOME:-$HOME/.cache/huggingface}"
find "$hf_root" -xdev -type f \
  \( -name 'tmp*' -o -name '*.incomplete' \) \
  -mtime +30 -printf '%12s  %TY-%Tm-%Td  %p\n' |
  sort -nr
```

Prefer `hf cache prune`; remove a legacy temporary path manually only after
confirming it is an abandoned regular file below that cache root.

Official reference:
[Hugging Face CLI cache management](https://huggingface.co/docs/huggingface_hub/en/guides/cli#hf-cache).

### pip

```bash
python -m pip cache dir
python -m pip cache info
python -m pip cache purge
```

This removes downloaded/build cache, not installed packages. Keeping caching
enabled normally avoids repeated downloads.

Official reference:
[pip cache management](https://pip.pypa.io/en/stable/topics/caching/).

### Conda

Preview first:

```bash
conda clean --all --dry-run
```

Then apply the same supported cleanup:

```bash
conda clean --all --yes
```

Do not substitute `--force-pkgs-dirs`. Conda warns that forcing all package
caches can break environments whose packages use cache symlinks.

Official reference:
[conda clean](https://docs.conda.io/projects/conda/en/stable/commands/clean.html).

### npm

Start with garbage collection and integrity verification:

```bash
npm cache verify
```

Only under real disk pressure:

```bash
npm cache clean --force
```

npm describes its cache as self-healing and normally recommends cleaning it
only to reclaim disk space.

Official reference:
[npm cache](https://docs.npmjs.com/cli/cache/).

### uv

Prefer periodic pruning:

```bash
uv cache dir
uv cache prune
```

For maximum reclaim:

```bash
uv cache clean
```

Do not clear a uv cache if projects deliberately use `symlink` link mode;
those environments can depend on cache files. The default clone/hardlink/copy
routes do not have that coupling.

Official reference:
[uv cache](https://docs.astral.sh/uv/concepts/cache/).

## 4. Deduplicate Downloads against authoritative projects

The trusted destination roots were selected before scanning:

```text
~/ProjectsLFS/OrganoidAgent
~/ProjectsLFS/Books
~/ProjectsLFS/ZhJpBook
~/ProjectsLFS/LALACHAN
```

The safe algorithm was:

1. Walk Downloads and the selected project roots without following directory
   symlinks or crossing filesystems.
2. Group regular files by byte size.
3. Hash only source/target groups with the same size. This avoids reading
   millions of unrelated files.
4. Record source path, size, SHA-256, and every matching project path.
5. Before deleting anything, re-open every source and one approved target,
   recompute both hashes, reject symlinks, and verify both paths remain below
   their allowed roots.
6. Do not remove any file until **all** report entries pass that second
   validation.
7. Remove only the Downloads side.
8. Confirm every removed source is absent and every preserved project copy
   still exists.

Filename, modification time, and file size alone were never treated as proof.
The second pass found 448 exact book copies and 51 exact MP4 copies, totaling
7,415,883,531 bytes.

This local hash method is intentionally **not** suitable for an optimized
iCloud Drive tree: reading placeholder contents can download them and stall
sync. Use bounded external staging for iCloud duplicates instead.

## 5. Review installers and opaque archives

The approved installer cleanup removed:

- one Xcode `.xip`;
- five `.deb` packages; and
- one `.dmg`.

A final recursive audit confirmed no `.deb` or `.dmg` remained:

```bash
find "$HOME/Downloads" -type f \
  \( -iname '*.deb' -o -iname '*.dmg' \) -print
```

An opaque 3.4 GiB ZIP was inspected rather than guessed. Its entry list,
top-level directory, size, timestamp, and SHA-256 identified it as a Leica
LAS X 4.7.0 Windows microscopy installer bundle. It was retained in
`Downloads/Archives`.

## 6. Organize without flattening

Every remaining top-level item was moved atomically on the same filesystem
into:

```text
Books/
Videos/
Audio/
Images/
Documents/
Archives/
Software/
Data/
Projects-and-Folders/
Other/
```

Preflight rules:

- reject a category path that already exists as a non-directory;
- reject every destination-name collision before moving anything;
- ignore the category directories on a rerun;
- leave every existing directory tree intact under
  `Projects-and-Folders`; and
- reverse already completed renames if a later rename fails.

Final direct-entry inventory:

| Category | Items | Size |
| --- | ---: | ---: |
| Archives | 43 | 6.6 GiB |
| Documents | 33 | 1.6 GiB |
| Projects-and-Folders | 23 | 852 MiB |
| Videos | 21 | 382 MiB |
| Images | 143 | 195 MiB |
| Software | 2 | 154 MiB |
| Data | 7 | 106 MiB |
| Audio | 7 | 48 MiB |
| Books | 3 | 5.7 MiB |
| Other | 1 | 8 KiB |

The idempotence check produced zero new moves.

## 7. Verify the result

```bash
df -hT "$HOME"
du -sh "$HOME/Downloads"
find "$HOME/Downloads" -mindepth 1 -maxdepth 1 -printf '%y  %f\n' | sort
```

Use `df` to judge reclaimed physical capacity. Use `du` and cache-tool reports
to explain where apparent usage remains.
