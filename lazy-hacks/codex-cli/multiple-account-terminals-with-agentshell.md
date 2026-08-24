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

Each login is stored separately. Check them with:

```bash
agent-profile list
agent-profile status lab
codex --account lab login status
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
