# Fast, Native-Compatible `codex`, `codexr`, and `codexfork`

## Outcome

These Linux/WSL wrappers keep the convenient exact-folder resume workflow without hiding current Codex features.

- `codex` retains its normal commands and parameters.
- `codexr` remains shorthand for `codex resume`.
- `codexfork` forks a session UUID and opens it in another existing folder.
- `/rename` names are visible in the fast picker.
- A saved name or UUID can be passed directly to native Codex.
- Up/Down, `j`/`k`, paging, and live filtering work in the custom picker.
- `--native` always opens the official Codex picker.
- Empty sessions and non-interactive worker sessions are hidden by default.

The wrapper still enforces the workstation defaults:

- sandbox: `danger-full-access`
- approval policy: `never`

## Installed files

The active implementation is deliberately shared by shell functions and command shims:

- `~/scripts/codex_wrapper.sh` — argument handling and native Codex dispatch
- `~/scripts/codex_session_tool.py` — indexed SQLite query, picker UI, and cwd migration
- `~/scripts/sourced_codex_wrappers.sh` — shell functions
- `~/bin/codex`, `~/bin/codexr`, `~/bin/codexfork`, `~/bin/codexmv` — non-interactive command shims
- `~/.bashrc` — sources `sourced_codex_wrappers.sh`, with the former definitions retained only as an emergency fallback

This fixes the previous split where an interactive shell and `~/bin` could run different generations of the wrapper.

## Native names and `/rename`

Current Codex stores a renamed chat in the `threads.name` field, separately from the older title/preview fields. The picker now chooses its display text in this order:

1. saved name from `/rename`
2. current preview
3. title
4. first user message

Named rows are shown as `Name: <saved name>`.

Resume a named session directly:

```bash
codexr ChipAgent
codex resume ChipAgent
```

The wrapper passes that value to native Codex, which accepts a session UUID or saved session name. After a session opens, rename it normally:

```text
/rename Better Name
```

The next fast-picker launch shows the new name. Picker selection itself uses the UUID, so duplicate or similar names cannot resume the wrong row.

## Fork into another folder

```bash
codexfork SESSION_ID FOLDER [PROMPT]
```

For example:

```bash
codexfork 019e1f99-289e-7711-986a-d41047f5ed21 ~/ProjectsLFS/LazyTravel
codexfork 019e1f99-289e-7711-986a-d41047f5ed21 . "Continue from the handoff"
```

The folder must already exist. The wrapper normalizes it to an absolute path, preserves the workstation's `danger-full-access` and `never` defaults, and delegates to native `codex fork --cd`. The optional prompt must be quoted when it contains spaces.

After the fork opens, give it a saved name with the native command:

```text
/rename LazyTravel
```

Official references:

- [Codex CLI command reference](https://learn.chatgpt.com/docs/developer-commands?surface=cli)
- [`codex resume` and `/rename`](https://learn.chatgpt.com/docs/developer-commands?surface=cli)

## Picker controls

```text
Up / Down or j / k    move selection
Enter                 resume selected session
PageUp / PageDown     move one visible page
Home / End            first or last row
/                     start text filtering
Backspace             edit filter
Esc                   leave filtering, or cancel picker
q                     cancel picker
```

Filtering searches the saved name, preview, title, first prompt, cwd, source, and UUID. It does not modify the Codex database.

## Resume scopes

### Exact current directory — default

```bash
codexr
codex resume
```

Only sessions whose stored cwd exactly equals `pwd -P` are shown. A session under a child directory is not included.

### Exact explicit directory

```bash
codexr -C /home/lachlan/ProjectsLFS/EchoMind
codex resume --cd /home/lachlan/ProjectsLFS/EchoMind
```

`--cwd` is also accepted as a compatibility alias and normalized to native `--cd`.

### All interactive sessions

```bash
codexr --all
codex resume --all
```

### Partial cwd lookup

```bash
codexr --non-strict EchoMind
codex resume --non-strict OpenHI
```

`--non-strict` is a wrapper-only option. It performs a case-insensitive partial match against stored cwd values. Once the rows appear, `/` can further filter them by name or text.

### Include workers and automation

```bash
codexr --all --include-non-interactive
```

By default, the picker uses only `source IN ('cli', 'vscode')`. `--include-non-interactive` includes `exec`, subagent, and other background records.

### Native picker

```bash
codexr --native
codex resume --native --all
```

`--native` is consumed by the wrapper. All other applicable arguments go to the official picker.

### Most recent session

```bash
codexr --last
```

`--last`, help/version requests, an explicit name/UUID, and unknown future options automatically bypass the custom picker. This preserves native behavior and forward compatibility.

## Parameter compatibility

Options known to current `codex resume` are retained when a custom-picker row is selected, including:

- `-m` / `--model`
- `-p` / `--profile`
- `-c` / `--config`
- `--enable` / `--disable`
- `-i` / `--image`
- `--remote` and `--remote-auth-token-env`
- `--strict-config`
- `--oss` and `--local-provider`
- `--add-dir`
- `--search`
- `--no-alt-screen`

For example:

```bash
codexr -m gpt-5.6-sol --search --no-alt-screen
codexr ChipAgent -m gpt-5.6-sol
```

Only mode arguments that conflict with the workstation policy are removed and replaced by `-s danger-full-access -a never`.

## Why it stays fast

The session database on this workstation is approximately 9.6 GB and contains more than 240,000 rows, mostly non-interactive execution records. A broad query can therefore be slow even though only a few hundred rows are human sessions.

The helper:

- reads SQLite in read-only mode for picking;
- uses `idx_threads_source` for interactive views;
- uses recency/cwd indexes for all-source views;
- limits the result set before rendering (500 by default, configurable with `CODEX_RESUME_PICKER_LIMIT`);
- does not scan rollout JSONL files.

Measured on 2026-08-10, exact, partial, and normal `--all` queries completed in about 0.06 seconds with a warm filesystem cache. Loading 500 rows with `--all --include-non-interactive` completed in about 0.22 seconds.

## Enable, disable, and reload

The picker is enabled on both native Linux and WSL:

```bash
CODEX_RESUME_PICKER_ENABLE_NATIVE=1
CODEX_RESUME_PICKER_ENABLE_WSL=1
CODEX_RESUME_PICKER_LIMIT=500
```

Set the platform value to `0` before sourcing the wrapper to default to native resume behavior. `--native` is the simpler one-command bypass.

Reload after an edit:

```bash
source ~/.bashrc
```

Validate command resolution:

```bash
type codex codexr codexfork codexmv cr
codex --version
codexr --help
codexfork --help
```
