# SafeShell: recoverable `rm` for Bash

SafeShell keeps normal shell muscle memory while making deletion recoverable:

- `rm` is an alias for `saferm`, which **moves** files into a mirrored trash tree.
- `unrm` restores by original path, direct trash path, or filename search.
- `removeitanyway` is the deliberately explicit permanent-delete command.

The implementation is in [`safeshell_functions.sh`](safeshell_functions.sh), and
its generated-file regression suite is in
[`test_safeshell.sh`](test_safeshell.sh).

## Why version 2 exists

The original helper worked for a single plain path, but treated every argument
as a filename. Consequently, a familiar command such as `rm -rf build` tried to
resolve `-rf` as a path. Its restore command also expanded `find` output through
whitespace-splitting, so spaces in filenames were unsafe, and passing a direct
`/mnt/disk/BIN/ROOT/...` path could prepend the trash root a second time.

Version 2 addresses those root causes:

- parses common GNU `rm` flags, combined flags, and `--`;
- keeps path operands in Bash arrays and consumes `find -print0` output;
- preserves symlinks rather than dereferencing them;
- distinguishes original paths from direct trash paths;
- refuses to overwrite anything during restore;
- preserves repeated removals as timestamped versions;
- prints an exact plan before permanent deletion;
- refuses broad system, home, mount, and trash-root targets;
- refuses to operate when the production trash disk is not mounted.

## Installation

SafeShell uses Bash features and should be **sourced**, not appended repeatedly
and not loaded as a Zsh script.

For a repository checkout:

```bash
source "$HOME/ProjectsLFS/the-art-of-lazying/scripts/lazy-care/SafeShell/safeshell_functions.sh"
```

For a workstation deployment, copy the canonical file to a stable scripts
location and source that one from `~/.bashrc`:

```bash
install -m 0644 \
  "$HOME/ProjectsLFS/the-art-of-lazying/scripts/lazy-care/SafeShell/safeshell_functions.sh" \
  "$HOME/scripts/sourced_saferemove.sh"

grep -qxF 'source "$HOME/scripts/sourced_saferemove.sh"' "$HOME/.bashrc" || \
  printf '%s\n' 'source "$HOME/scripts/sourced_saferemove.sh"' >>"$HOME/.bashrc"
source "$HOME/.bashrc"
```

Add the `source` line only once. New terminals then load SafeShell
automatically. Existing terminals can reload it with:

```bash
. "$HOME/.bashrc"
```

Verify the active definitions:

```bash
type rm saferm unrm removeitanyway
```

## Trash layout and mount guard

The workstation default is:

```text
/mnt/disk/BIN/ROOT
```

SafeShell mirrors each absolute path below that root:

```text
/home/alice/project/result.db
  -> /mnt/disk/BIN/ROOT/home/alice/project/result.db
```

If the same original path is removed again, the existing entry is retained and
the newer entry receives a collision suffix:

```text
result.db.~saferm~20260830T120102.123456789Z~12345
```

Legacy `_YYYY-MM-DD_HH-MM-SS` suffixes remain restorable. When using the default
path, `/mnt/disk` must be a real mounted filesystem; otherwise SafeShell stops
without changing the source. This prevents an unavailable disk from silently
turning `/mnt/disk` into an ordinary directory on `/`.

For another machine or an isolated test, explicitly set a different root:

```bash
export SAFERM_TRASH_ROOT="$HOME/.local/share/safeshell/ROOT"
source ./safeshell_functions.sh
```

An explicit override intentionally bypasses the `/mnt/disk` mount check.

## Recoverable removal

Ordinary `rm` now invokes `saferm`:

```bash
rm report.pdf
rm -rf ./generated-build
rm -f missing-file
rm -rv "folder with spaces"
rm -- -filename-starting-with-dash
```

Supported compatibility options include:

- `-f`, `--force`
- `-r`, `-R`, `--recursive`
- `-d`, `--dir`
- `-i`, `-I`, `--interactive=always|once|never`
- `-v`, `--verbose`
- `--one-file-system`
- `--preserve-root`
- `--`

Recursive flags are accepted for command compatibility; `mv` already moves an
entire directory. `--no-preserve-root` is intentionally rejected.

## Restore with `unrm`

Restore from the current directory, an absolute path, or a `../` path:

```bash
unrm ./generated-build
unrm ../notes/report.md
unrm /home/alice/project/result.db
```

Restore by a direct trash path without duplicating the trash prefix:

```bash
unrm /mnt/disk/BIN/ROOT/home/alice/project/result.db
```

Restore to a different path:

```bash
unrm ./result.db --to ../recovered/result.db
unrm ./result.db ../recovered/result.db
```

If the destination already exists and is a directory, the restored item is put
inside it. Any existing final destination is otherwise refused—`unrm` never
overwrites it.

Inspect or select repeated versions:

```bash
unrm --list ./result.db
unrm --newest ./result.db
```

A bare filename falls back to an exact basename search:

```bash
unrm result.db
```

An intentional substring search is also available:

```bash
unrm --search project/result
```

When several entries match, an interactive shell presents a numbered list. In
automation, choose explicitly with `--newest` after inspecting `--list`.

## Permanent deletion

`removeitanyway` checks both the current path and all exact SafeShell versions,
prints every target, and requires the full word `yes`:

```bash
removeitanyway -rf ./generated-build
```

For deliberate non-interactive cleanup of generated data:

```bash
removeitanyway --yes -rf ./generated-build
```

`-f` suppresses missing-path errors but does **not** bypass confirmation. A
direct trash path deletes only that selected trash entry:

```bash
removeitanyway /mnt/disk/BIN/ROOT/home/alice/project/old-result.db
```

Broad roots such as `/`, `/home`, the user's home, `/mnt/disk`, the trash root,
and their high-level mirrors are always rejected.

## Validation

The test suite creates its own temporary workspace and trash root and never
touches production data:

```bash
bash -n safeshell_functions.sh
bash -n test_safeshell.sh
bash test_safeshell.sh
```

It covers spaces, recursive flags, `./` and `../`, absolute paths,
dash-leading filenames, direct trash paths, alternate destinations, repeated
versions, `--newest`, `-f`, permanent deletion, and protected roots.

## Operational notes

- A wrong or not-yet-mounted `/mnt/disk` can explain `mkdir`/`mv` permission or
  missing-directory errors; it is separate from option parsing and restore
  logic. Version 2 fails closed when this occurs.
- SafeShell does not silently fall back to `/bin/rm` if its trash is
  unavailable.
- Existing empty mirror directories are retained because old trash layouts do
  not distinguish an empty directory that was itself removed from a directory
  created only as a parent. Preserving it is safer than guessing.
- Use `/bin/rm` only in carefully scoped maintenance or tests when bypassing the
  alias is genuinely intended.
