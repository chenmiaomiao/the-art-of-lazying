# Codex CLI Hacks

This folder stores practical Codex CLI workflow tweaks used on this machine.

## Files
- [codex-and-codexr.md](./codex-and-codexr.md)
  - current Linux/WSL behavior for `codex`, `codexr`, `codexfork`, and `cr`
  - fast SQLite picker with saved `/rename` names and arrow-key navigation
  - native session forking into another existing folder
  - exact cwd, `--all`, `--native`, `--non-strict`, and parameter passthrough
  - enforced `danger-full-access` + `never`
- [codexmv-session-migration.md](./codexmv-session-migration.md)
  - migrate stored Codex session cwd mappings after a repo move or rename
  - name preservation, private rollback journals, and picker choices
  - `--latest`, `--no-resume`, and `--native`
  - includes the `nhi_reconstruction -> OpenHI` example
- [macos-zsh-full-setup.md](./macos-zsh-full-setup.md)
  - self-contained macOS `zsh` setup for `codex`, `codexr`, and `codexmv`
- [windows-powershell-full-setup.md](./windows-powershell-full-setup.md)
  - self-contained Windows PowerShell setup and installer for `codex`, `codexr`, `cr`, and `codexmv`
- [codexmv-macos-zsh.md](./codexmv-macos-zsh.md)
  - macOS `zsh` tutorial for `codexmv`
- [image-drag-drop-paths.md](./image-drag-drop-paths.md)
  - notes on Codex image drag/drop including local path metadata
- [codex-session-recovery.md](./codex-session-recovery.md)
  - broken `codex resume` recovery after CLI/API format drift
  - exact same-ID repair for `Unknown parameter: 'input[...].namespace'`
  - byte-identical backup, structured `jq` migration, semantic digest, rollback, and tmux verification
  - conservative replacement-thread fallback when the same-ID scope gate fails
- [multiple-account-terminals-with-agentshell.md](./multiple-account-terminals-with-agentshell.md)
  - separate personal, lab, and company Codex logins by named terminal
  - `codex/codexr/codexmv --account NAME` with unchanged native argument forwarding
  - persistent `agentshell NAME` terminals that keep the real working directory
  - optional Claude, Gemini, and Copilot CLI account adapters
  - credential inheritance safeguards, state paths, installation, and verification

## Scope
These docs assume Codex local state under:
- `~/.codex`

The Linux `bash` docs reflect the wrappers currently used from:
- `~/.bashrc`

The Windows PowerShell docs install wrappers into:
- `%USERPROFILE%\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1`
- `%USERPROFILE%\Documents\PowerShell\Microsoft.PowerShell_profile.ps1`
