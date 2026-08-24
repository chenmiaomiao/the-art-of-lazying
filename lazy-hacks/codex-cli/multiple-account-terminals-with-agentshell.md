# Separate Codex accounts by terminal with AgentShell

## Goal

Use personal, lab, and company AI accounts in different terminals while every terminal works on the same real project folder.

The resulting boundary is application state, not a container:

```text
/same/project
  ├── terminal: personal → personal Codex login and sessions
  ├── terminal: lab      → lab Codex login and sessions
  └── terminal: company  → company Codex login and sessions
```

This is implemented by [AgentShell](https://github.com/lachlanchen/AgentShell). It uses Codex's supported `CODEX_HOME` setting instead of changing Unix users, copying projects, or creating Docker bind mounts.

The complete upstream tutorial is also available in [AgentShell's documentation](https://github.com/lachlanchen/AgentShell/blob/main/docs/tutorial.md).

## The three commands to remember

Run these in any terminal, from whichever directory it already uses:

```bash
source ~/.bashrc
agentshell personal
codexr
```

Replace `personal` with `lab` or `company`. Inside that named shell, plain `codex`, `codexr`, and `codexmv` use the selected account.

Only the first login needs:

```bash
source ~/.bashrc
codex --account personal login
agent-profile history personal shared
```

## Understand the two kinds of profile

AgentShell's `--account` chooses a separate authentication/state directory:

```bash
codex --account personal
```

Codex's native `--profile`/`-p` option chooses a configuration profile; it does not switch ChatGPT logins. The AgentShell option must come first so the Bash dispatcher can consume it:

```bash
# Correct
codex --account lab -m gpt-5.6-sol "Review this project"

# Incorrect
codex -m gpt-5.6-sol --account lab
```

## Installed commands

The most direct form is:

```bash
codex --account personal
codex --account lab
codex --account company
```

The account option must be first. All remaining native Codex options and prompts pass through unchanged:

```bash
codex --account lab -m gpt-5.6-sol
codex --account company "Review the current repository"
codexr --account lab --all
codexmv --account lab /old/repo /new/repo
```

Without `--account` or `--project`, the existing workstation wrappers behave exactly as before:

```bash
codex
codexr
codexmv
```

## First login for each account

```bash
agent-profile create personal
agent-profile create lab
agent-profile create company

codex --account personal login
codex --account lab login
codex --account company login
```

Each command opens Codex's normal browser flow. Sign in with the intended account for that label. On a remote/headless terminal, use device authentication:

```bash
codex --account personal login --device-auth
```

The profile-management spelling is equivalent:

```bash
agent-profile login personal codex
```

Each login is stored separately. Check it with:

```bash
agent-profile list
agent-profile status lab
codex --account lab login status
```

Inside Codex, `/status` is the best check for the exact authenticated identity. To replace one profile's login without touching the others:

```bash
codex --account lab logout
codex --account lab login
```

## Choose private or shared history

Authentication and session indexing are separate choices. Keep each account's SQLite history private:

```bash
agent-profile history company private
```

Or let several account logins use the existing shared Codex history:

```bash
agent-profile history personal shared
agent-profile history lab shared
agent-profile history company shared
```

The login remains in each profile's private `CODEX_HOME`; only `CODEX_SQLITE_HOME` points at the shared index. The workstation's `personal`, `lab`, and `company` profiles currently use shared mode so `codexr --account NAME` can find the established sessions.

Use private mode when company or lab policy should prevent titles/previews from appearing across account profiles.

Changing modes does not delete either index. It only chooses which SQLite location subsequent commands use.

## Dedicate a terminal to one account

The cleanest long-running workflow is a named shell:

```bash
cd /path/to/project
agentshell lab
```

The prompt gains an `[agent:lab]` prefix. Within that terminal, plain commands use the lab account:

```bash
codex
codexr
codexmv
```

`pwd` remains `/path/to/project`. Run `exit` to return to the parent shell.

Open another terminal and run `agentshell personal` to use a different account against the same folder.

Show the active terminal profile at any time:

```bash
agentshell -v
```

It prints the AgentShell version, current account, login state, history mode, Codex/SQLite homes, and working directory. In an ordinary shell it reports that no profile is active. Codex's own `/status` remains the best check for the authenticated account identity inside the TUI.

A one-shot child process such as `codex --account personal` cannot alter its parent terminal's environment. Its launch banner names the profile; use `agentshell status personal` from the parent shell or `/status` inside Codex.

## Resume sessions

The workstation picker defaults to sessions whose stored working directory exactly equals the current directory:

```bash
cd /path/to/project
codexr --account personal
```

Useful alternatives:

```bash
# All working directories
codexr --account personal --all

# Partial path search
codexr --account personal --non-strict EchoMind

# Include non-interactive runs
codexr --account personal --all --include-non-interactive

# Official/native picker
codexr --account personal --native

# Most recent native session
codex --account personal resume --last

# Resume a UUID or /rename name
codex --account personal resume SESSION_ID_OR_NAME
```

`--non-strict` is a `codexr` wrapper option. `codex non-strict incoder` is not valid.

## Move sessions after renaming a project folder

`codexmv` updates the recorded working-directory metadata; it does not move project files:

```bash
codexmv --account personal /old/project/path /new/project/path
```

The wrapper writes a rollback journal before changing SQLite. Additional modes are:

```bash
codexmv --account personal --latest /old/path /new/path
codexmv --account personal --no-resume /old/path /new/path
codexmv --account personal --native /old/path /new/path
```

## Generated shortcuts

Creating the `lab` profile also creates:

```text
agent-lab-codex
agent-lab-codexr
agent-lab-codexmv
agent-lab-claude
agent-lab-gemini
agent-lab-copilot
```

The following are equivalent:

```bash
codex --account lab --version
agent-codex --account lab --version
agent-lab-codex --version
agent-run --account lab codex --version
```

`--project` is accepted as a friendlier synonym when the label represents a work context:

```bash
codex --project lab
```

## General AI CLI framework

AgentShell also sets documented profile roots for terminal versions of Claude Code, Gemini CLI, and GitHub Copilot CLI:

```bash
claude --account lab
gemini --account personal
copilot --account company
```

Inside `agentshell lab`, plain invocations of those tools use the lab profile. Codex is the primary and fully integrated workflow; the other providers use their official state-directory adapters:

- [Codex `CODEX_HOME`](https://learn.chatgpt.com/docs/config-file/environment-variables)
- [Claude `CLAUDE_CONFIG_DIR`](https://code.claude.com/docs/en/env-vars)
- [Gemini `GEMINI_CLI_HOME`](https://github.com/google-gemini/gemini-cli/blob/main/docs/reference/configuration.md)
- [Copilot `COPILOT_HOME`](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference)

## State and safety

Profiles live under:

```text
~/.local/share/agentshell/profiles/ACCOUNT/
```

AgentShell isolates known authentication and session locations. It does not copy default authentication files. It clears inherited provider API-token variables before launch so a global token cannot silently override the chosen profile. A profile can deliberately define account-specific variables in its private, mode-0600 `env.sh`.

Authored Codex settings and workstation skills remain available. Credentials are always profile-local; SQLite history is private by default and shared only when explicitly selected. The same Unix user still owns every process, so this is not a security sandbox; use separate Unix users or containers when mutually untrusted users need OS-level isolation.

The workstation `codexr` and `codexmv` wrapper now resolves its database from `CODEX_SQLITE_HOME`, falling back to `CODEX_HOME`. A brand-new private profile without a database falls back to Codex's native picker instead of producing a Python traceback or a hard missing-database error.

## Installation and updates

The source checkout is:

```text
~/ProjectsLFS/AgentShell
```

Install or refresh it with:

```bash
cd ~/ProjectsLFS/AgentShell
git pull --rebase
./install.sh
. ~/.bashrc
```

The installer places the runtime under `~/.local/lib/agentshell`, command links under `~/.local/bin`, and Bash integration at `~/scripts/sourced_agent_shell.sh`. The `.bashrc` integration is marked with `>>> AgentShell` / `<<< AgentShell` and is loaded after the existing Codex wrapper definitions.

## Verification

```bash
type codex
agentshell --help
agentshell -v
agentshell status personal
agent-profile list
codex --version
codex --account lab --version
```

Expected behavior:

- plain `codex --version` still works;
- account-aware invocation creates or reuses only that named profile;
- `agent-profile list` shows the label;
- current-directory access is unchanged;
- no default `~/.codex/auth.json` is copied into the profile.

If `codex --account NAME` reaches native Codex and reports that `--account` is unknown, reload the Bash integration once:

```bash
. ~/.bashrc
```

New terminals load it automatically.

### The profile has no SQLite database

Inspect the selected route:

```bash
agentshell status personal
```

Use the established workstation index when desired:

```bash
agent-profile history personal shared
```

A new private profile may have no database until Codex first writes state. The wrapper falls back to Codex's native picker rather than treating that as corruption.

### No sessions appear for the current folder

```bash
codexr --account personal --all
codexr --account personal --non-strict PART_OF_PATH
```

Use `codexmv` when the directory itself was renamed.

### The browser used the wrong ChatGPT account

```bash
codex --account personal logout
codex --account personal login
```

Then verify with `/status` inside Codex.

### Browser login cannot return to a remote terminal

```bash
codex --account personal login --device-auth
```

### `agentshell -v` says `none (ordinary shell)`

Inspect a label explicitly or enter a dedicated shell:

```bash
agentshell status personal
agentshell personal
agentshell -v
```

### Ctrl+C prints `KeyboardInterrupt` from the picker

The picker was cancelled; the session database was not damaged. Run it again or use `q` to leave the picker.

## Complete daily-use cheat sheet

```bash
# Load/update the current terminal integration
. "$HOME/.bashrc"

# Create and inspect
agent-profile create personal
agent-profile list
agentshell status personal

# Login and logout
codex --account personal login
codex --account personal login --device-auth
codex --account personal login status
codex --account personal logout

# History routing
agent-profile history personal shared
agent-profile history personal private

# One-shot use and resume
codex --account personal
codexr --account personal
codexr --account personal --all

# Dedicated terminal
agentshell personal
agentshell -v
exit

# Moved project directory
codexmv --account personal /old/path /new/path

# Update AgentShell
cd "$HOME/ProjectsLFS/AgentShell"
git pull --rebase
./install.sh
. "$HOME/.bashrc"
```

## Privacy boundary

Never commit or upload profile `auth.json` files, tokens, cookies, or raw private histories. Shared history intentionally exposes indexed titles, previews, and paths to each profile using the index. AgentShell is convenient state separation for one trusted Unix user, not an OS security boundary.
