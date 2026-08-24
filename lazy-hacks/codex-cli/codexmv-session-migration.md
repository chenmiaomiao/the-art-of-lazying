# `codexmv`: Move Sessions After a Repository Rename

## Purpose

`codexmv` changes the stored working-directory prefix for Codex sessions after a project folder is moved or renamed. It changes session metadata only; it does not move project files, alter the transcript, or remove a saved `/rename` name.

## Syntax

```bash
codexmv [--latest|-l] [--no-resume] [--native] <oldpath> [newpath]
```

- `oldpath` is required.
- `newpath` defaults to the current directory.
- `--latest` / `-l` resumes the newest migrated session directly.
- `--no-resume` performs only the migration.
- `--native` opens the official Codex picker after migration.
- Default behavior opens the fast name-aware picker in the new directory.

## Examples

```bash
# Old sibling folder -> current folder
cd ~/ProjectsLFS/OpenHI
codexmv ../nhi_reconstruction .

# Explicit old and new roots
codexmv ~/Projects/old-project ~/Projects/new-project

# Move metadata without opening another Codex UI
codexmv --no-resume ~/Projects/old-project ~/Projects/new-project

# Resume the most recently active migrated session
codexmv --latest ~/Projects/old-project ~/Projects/new-project

# Use the official picker after moving
codexmv --native ~/Projects/old-project ~/Projects/new-project
```

Paths are expanded and normalized to absolute paths. Both an exact stored cwd and all descendants are migrated while preserving each descendant suffix.

```text
old root:  /a/old
old cwd:   /a/old/service/api
new root:  /b/new
new cwd:   /b/new/service/api
```

## Current storage behavior

The current Linux implementation updates `state_5.sqlite` under `CODEX_SQLITE_HOME`, falling back to `CODEX_HOME` and then `~/.codex`:

```text
$CODEX_SQLITE_HOME/state_5.sqlite
└── threads.cwd
```

It does not rewrite rollout JSONL history. Current Codex resume discovery and saved names are represented in the state database; leaving transcripts untouched minimizes risk and preserves `/rename` data exactly.

The migration uses parameterized SQLite updates in one transaction. It refuses `/` as an old root.

## Rollback journal

The workstation state database is about 9.6 GB, so creating a full database copy for every small folder rename would be wasteful. Before changing rows, `codexmv` writes a small private journal instead:

```text
~/.codex/backups/codexmv/move-YYYYMMDD-HHMMSS-microseconds.json
```

The journal has mode `0600` and records:

- session UUID;
- old cwd;
- new cwd;
- old and new roots;
- database path and timestamp.

This is sufficient to audit or reverse the narrow cwd change without duplicating the entire database.

## Names are preserved

`codexmv` updates only `threads.cwd`. It does not update `threads.name`, `preview`, `title`, transcript content, pin state, or timestamps. A session named with `/rename` therefore keeps the same name and appears as `Name: ...` in the destination picker.

## Troubleshooting

### No sessions found

```text
codexmv: no sessions found under old path: ...
```

Check the original path with:

```bash
codexr --all --non-strict old-folder-name
```

### Use native resume after migration

```bash
codexmv --native /old/path /new/path
```

### Reload wrapper definitions

```bash
source ~/.bashrc
type codexmv
```

## Implementation

- `~/scripts/codex_wrapper.sh`
- `~/scripts/codex_session_tool.py`
- `~/scripts/sourced_codex_wrappers.sh`
- `~/bin/codexmv`
