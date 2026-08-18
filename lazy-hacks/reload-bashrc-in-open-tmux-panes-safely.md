# Reload `.bashrc` in Existing Terminals Without Disturbing Work

## The simple command

For one interactive Bash terminal, use either form:

```bash
source /home/lachlan/.bashrc
. /home/lachlan/.bashrc
```

The second form is POSIX shell syntax. The absolute path is useful through a
remote keyboard that cannot type `~` reliably. On another account, replace
`/home/lachlan` with that account's home directory. When `$` is easy to type,
the portable equivalent is:

```bash
. "$HOME/.bashrc"
```

Sourcing changes only the current shell. New terminals read `.bashrc`
normally, while already-open terminals must each source it once.

## Validate before touching live panes

Always parse the file in a disposable Bash process first:

```bash
bash -n "$HOME/.bashrc"
```

No output and exit status zero means Bash accepted the syntax. It does not
prove that every sourced helper behaves correctly, so reload one ordinary
terminal first before applying the change to several panes.

## Safe tmux procedure

Do not broadcast to every tmux pane. Some panes may own Codex, a build, a
server, a text editor, or a command with unfinished input. Start with an
inventory:

```bash
tmux list-panes -a -F \
  '#{session_name}:#{window_index}.#{pane_index} #{pane_id} #{pane_pid} #{pane_current_command} #{pane_current_path}'
```

For each candidate pane:

1. Require `pane_current_command` to be an interactive shell such as `bash`.
2. Confirm that the shell itself owns the terminal's foreground process group:

   ```bash
   ps -o pid=,pgrp=,tpgid=,stat=,comm= -p PANE_PID
   ```

   The shell PID and foreground `tpgid` should agree. If another foreground
   process owns the pane, skip it.
3. Inspect the visible tail before sending anything:

   ```bash
   tmux capture-pane -p -t PANE_ID -S -12
   ```

   Proceed only when a normal prompt or a completely idle blank prompt is
   visible. Skip log output, a partial command, password entry, a running
   program, or anything uncertain.
4. Reload only that confirmed pane:

   ```bash
   tmux send-keys -t PANE_ID '. "$HOME/.bashrc"' Enter
   ```

5. Capture the tail again and check for source, syntax, or helper errors.

The command text will visibly appear at the prompt and may enter shell
history. That is expected: `tmux send-keys` behaves like typing. Avoid adding
`Ctrl-U`, `clear`, or other cosmetic keystrokes; they can erase pending input
or hide evidence needed to notice a failed reload.

In one shared-workstation run, this process safely reloaded 19 clearly idle
shell panes and deliberately skipped three panes whose visible output was not
unambiguously idle. No app, service, Codex process, or non-tmux terminal was
interrupted.

## Why not force every terminal

There is no general, safe way for one process to source a file inside every
unrelated already-running shell. The environment belongs to each shell
process. Input injection into an arbitrary GUI terminal can hit a running
program or unfinished command, and kernel-level terminal injection is neither
portable nor appropriate for routine configuration.

Use the checked tmux method for clearly idle panes. For ordinary GUI terminals,
run the one-line command manually or open a new terminal.

## Remote Japanese keyboard note

Typing problems and shell reloads are separate issues. A Japanese JIS layout
normally maps `Shift+6` to `&`; a US layout maps it differently. A nested
Mac-to-Windows-to-RDP or VNC path may also fail to transport the physical
Kana/Eisu or symbol keys faithfully. Using an absolute source path avoids the
tilde problem without changing the desktop keyboard map and therefore does
not risk breaking a currently usable remote route.
