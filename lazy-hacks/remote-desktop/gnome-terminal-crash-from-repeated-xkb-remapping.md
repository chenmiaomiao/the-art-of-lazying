# GNOME Terminal windows vanished while tmux work survived

## Symptom

Every visible GNOME Terminal window can disappear at once even though the machine did not reboot and tmux sessions remain alive. GNOME Terminal normally places many windows behind one per-user `gnome-terminal-server`; a crash in that shared process removes all of its GUI windows together.

Recover project work first:

```bash
tmux list-sessions
tmux attach -t SESSION
```

Open a fresh terminal window only after checking tmux. Do not kill unrelated shells or project services.

## Evidence from the 2026-08-30 incident

The workstation showed:

- no reboot and no kernel OOM event;
- live tmux sessions and Codex processes;
- one `gnome-terminal-server` SIGSEGV in GTK's draw/signal path;
- an Apport report under `/var/crash/`;
- repeated `xkbcomp` and GNOME `Overwriting existing binding` messages every few seconds;
- six old copies of a Caps Lock repair watcher across several remote desktop sessions.

The immediate cause of the disappearing windows was the terminal server's GTK segmentation fault. The exact GTK defect cannot be proven from an unsymbolized core alone, but the continuous XKB rebuild storm was a strong, actionable trigger: the old watcher ran `setxkbmap -option caps:none` on every polling cycle even when the option was already active.

## Robust Caps Lock repair

Use [ensure-capslock-off.sh](scripts/ensure-capslock-off.sh). It has three important properties:

1. A per-display `flock` permits only one watcher for each X display.
2. It reads the complete `options:` line from `setxkbmap -query`; it does not split `caps:none` at the colon.
3. It changes the XKB map only when Caps Lock is latched or `caps:none` is actually absent.

Install it in an XDG autostart entry if persistent remote-session repair is needed:

```ini
[Desktop Entry]
Type=Application
Name=Ensure Caps Lock Off
Exec=/absolute/path/ensure-capslock-off.sh --watch
X-GNOME-Autostart-enabled=true
```

Validate the script and inspect the current session:

```bash
bash -n /absolute/path/ensure-capslock-off.sh
setxkbmap -query
xset q | grep 'Caps Lock'
pgrep -af 'ensure-capslock-off.sh --watch'
journalctl --user --since '10 minutes ago' | grep -E 'xkbcomp|Overwriting existing binding'
```

One watcher per active display is expected. A warning burst during the one-time map correction is acceptable; recurring bursts at the polling interval are not.

## Diagnostic checklist

```bash
uptime
free -h
tmux list-sessions
journalctl -k --since '30 minutes ago' | grep -Ei 'oom|segfault|nvrm|xid'
journalctl --user --since '30 minutes ago' | grep -Ei 'gnome-terminal|segfault|xkbcomp'
ls -lh /var/crash/
```

This distinguishes a terminal GUI crash from a reboot, OOM kill, GPU reset, or loss of the underlying tmux work.
