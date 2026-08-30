# Lazy Care

This directory collects small tools that make routine workstation maintenance
safer and easier to reverse.

## SafeShell

[`SafeShell/`](SafeShell/) provides three Bash commands:

- `rm` / `saferm`: move paths into a mirrored trash tree instead of deleting;
- `unrm`: restore by original, relative, or direct trash path;
- `removeitanyway`: permanently remove only after showing an exact plan.

The current implementation correctly handles ordinary `rm -rf`, combined
flags, whitespace, symlinks, repeated versions, `./` and `../` paths, explicit
restore destinations, and dash-leading filenames. It also refuses to operate
if the production trash disk is not mounted.

Read the complete setup, usage, recovery, and test guide in
[`SafeShell/README.md`](SafeShell/README.md).
