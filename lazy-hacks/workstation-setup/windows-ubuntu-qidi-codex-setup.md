# Windows, Ubuntu Dual-Boot, QIDI Studio, and Codex Setup Notes

This note records the operational setup pattern used on the lab workstation.
It intentionally excludes passwords, private keys, public key bodies, tokens,
and raw `known_hosts` contents.

## Machines

| Role | Example address | Notes |
| --- | --- | --- |
| Main Windows workstation | `192.168.1.166` | Runs PowerShell, Windows Terminal, QIDI Studio, LabCanvas, and SSH clients. |
| Dual-boot OptiPlex 7090 | `192.168.1.227` | Boots either Ubuntu or Windows. Same IP, different SSH servers and host keys. |
| DD-WRT router | `192.168.1.1` | Used to observe DHCP/active clients and static lease planning. |

## Problem 1: Dual-Boot SSH Host Key Conflicts

### Symptom

When the OptiPlex boots from Ubuntu and then later from Windows, SSH reports:

```text
WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!
Host key verification failed.
```

### Cause

Ubuntu OpenSSH and Windows OpenSSH are different SSH servers. They present
different host keys even though the IP address is the same.

Deleting `known_hosts` works temporarily, but it is the wrong durable fix.

### Durable Fix

Use SSH aliases with `HostKeyAlias`, so each operating system gets a separate
trusted host-key identity.

Example `~/.ssh/config` pattern:

```sshconfig
Host 227-windows win-227
    HostName 192.168.1.227
    User Administrator
    HostKeyAlias 227-windows
    IdentityFile ~/.ssh/id_ed25519_7090
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new

Host 227-ubuntu ubuntu-227 7090
    HostName 192.168.1.227
    User lachlan
    HostKeyAlias 227-ubuntu
    IdentityFile ~/.ssh/id_ed25519_7090
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
```

Use:

```powershell
ssh 227-windows
ssh 227-ubuntu
ssh 7090
```

Avoid using raw `ssh user@192.168.1.227` for a dual-boot host unless you are
prepared for host-key conflicts.

## Problem 2: One-Way Reachability After Rebooting Into Windows

### Symptom

The remote Windows machine can ping the main workstation, but the main
workstation cannot ping, SSH, or RDP into the remote machine.

### Diagnosis Pattern

From the main Windows workstation:

```powershell
ping 192.168.1.227
arp -a 192.168.1.227
```

If ARP resolves the MAC address but ping and TCP ports fail, layer 2 is working.
The likely cause is Windows Firewall profile or missing/stopped services on the
remote Windows boot.

Probe common ports:

```powershell
Test-NetConnection 192.168.1.227 -Port 22
Test-NetConnection 192.168.1.227 -Port 3389
Test-NetConnection 192.168.1.227 -Port 445
Test-NetConnection 192.168.1.227 -Port 5985
```

### Windows-Side Fix

Run on the remote Windows machine as Administrator:

```powershell
Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private

New-NetFirewallRule `
  -DisplayName "Allow ICMPv4 Ping" `
  -Direction Inbound `
  -Protocol ICMPv4 `
  -IcmpType 8 `
  -Action Allow `
  -Profile Any `
  -ErrorAction SilentlyContinue

Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Set-Service sshd -StartupType Automatic
Start-Service sshd

New-NetFirewallRule `
  -DisplayName "OpenSSH Server" `
  -Direction Inbound `
  -Protocol TCP `
  -LocalPort 22 `
  -Action Allow `
  -Profile Any `
  -ErrorAction SilentlyContinue

Set-ItemProperty `
  "HKLM:\System\CurrentControlSet\Control\Terminal Server" `
  -Name fDenyTSConnections `
  -Value 0
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
```

If port 22 changes from timeout to actively refused, the firewall is no longer
the blocker; `sshd` is not installed or not running.

## Problem 3: Passwordless SSH For Both Ubuntu and Windows

### Approach

Use one dedicated client key for this dual-boot host. Add the same public key to:

| Booted OS | Authorized key location |
| --- | --- |
| Ubuntu | `~/.ssh/authorized_keys` |
| Windows normal user auth | `%USERPROFILE%\.ssh\authorized_keys` |
| Windows administrator auth | `%ProgramData%\ssh\administrators_authorized_keys` |

Do not commit private keys or public key contents to any repository.

### Windows Administrator Key Permissions

Windows OpenSSH is strict about administrator key file permissions. A safe ACL
shape is:

```powershell
icacls "$env:ProgramData\ssh\administrators_authorized_keys" `
  /inheritance:r `
  /grant "Administrators:F" `
  /grant "SYSTEM:F"
```

After this, test without password prompts:

```powershell
ssh 227-windows "whoami && hostname"
ssh 227-ubuntu "whoami && hostname"
```

## Problem 4: Installing Node, npm, and Codex CLI on Ubuntu

### Node and npm

Ubuntu install:

```bash
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates nodejs npm
node --version
npm --version
```

Observed setup:

```text
node v18.x
npm 9.x
```

### Codex CLI

Current OpenAI Codex CLI installation guidance uses the standalone Linux
installer rather than relying on the older npm global package path.

Install:

```bash
curl -fsSL https://chatgpt.com/codex/install.sh | sh
```

Ensure user-local binaries are on PATH:

```bash
mkdir -p "$HOME/.local/bin"
grep -q 'HOME/.local/bin' "$HOME/.bashrc" || cat >> "$HOME/.bashrc" <<'EOF'

if [ -d "$HOME/.local/bin" ]; then
  PATH="$HOME/.local/bin:$PATH"
fi
EOF
```

Check:

```bash
export PATH="$HOME/.local/bin:$PATH"
command -v codex
codex --version
```

Observed setup:

```text
codex-cli 0.142.x
```

## Problem 5: QIDI Studio Install and Noisy Terminal Logs

### Install Pattern

QIDI Studio for the QIDI Max 4 was installed from the official QIDI/GitHub
release installer. When the silent installer did not register cleanly, the NSIS
package was extracted as a portable-style install:

```text
C:\Program Files\QIDIStudio\qidi-studio.exe
```

Bundled runtimes were installed from the extracted `plugin` directory when
needed.

### Logless Launch Pattern

Launching GUI apps directly from PowerShell can leave stdout/stderr attached to
the terminal. Use a detached `wscript.exe` launcher instead.

Example launcher:

```vbscript
Set shell = CreateObject("WScript.Shell")
shell.CurrentDirectory = "C:\Program Files\QIDIStudio"
shell.Run Chr(34) & "C:\Program Files\QIDIStudio\qidi-studio.exe" & Chr(34), 1, False
```

Create Desktop/Start Menu shortcuts pointing to:

```text
C:\Windows\System32\wscript.exe
```

with the `.vbs` launcher as the argument.

## Problem 6: QIDI Studio 100% Infill

In QIDI Studio:

```text
Prepare tab -> Process panel -> Strength -> Sparse infill density = 100%
Sparse infill pattern = Rectilinear
```

If the setting is hidden, switch the process mode from Basic to Advanced or
Expert.

`Slice plate` means slice only the currently selected build plate.

`Slice all` means slice every plate in the project.

For one STL on one plate, use `Slice plate`.

## Problem 7: Material-Aware QIDI Defaults

LabCanvas was extended with a QIDI helper that records material-aware defaults
instead of hardcoding one print profile for everything.

Default policy:

| Material | Enclosure / sealed printing | Drying | Typical default |
| --- | --- | --- | --- |
| PLA | Open / lid off | Optional unless brittle or stringing | Low infill, gyroid |
| PETG | Open or lightly enclosed | Recommended | Medium infill, gyroid |
| ABS / ASA | Sealed enclosure | Recommended | Brim, moderate speed |
| TPU / TPE | Open | Strongly recommended | Slow flexible profile |
| PA / Nylon | Sealed enclosure | Mandatory | Brim, dry spool |
| PC | Sealed enclosure | Mandatory | Brim, dry spool |
| CF / GF filled | Depends on base polymer | Mandatory | Hardened nozzle |

Watertight prints should not rely on infill alone. Increase wall loops, top and
bottom shell layers, control seam placement, and tune layer bonding.

## Problem 8: LabCanvas QIDI Tooling

The local LabCanvas repo was extended with:

```text
agentic_tools/qidi_studio_agent/
labcanvas qidi ...
```

Useful commands:

```powershell
labcanvas qidi doctor
labcanvas qidi status
labcanvas qidi material --material PLA
labcanvas qidi material --material PETG --part-intent watertight
labcanvas qidi open --input C:\path\to\part.stl
labcanvas qidi slice --input C:\path\to\part.stl --material PETG --part-intent watertight --auto-material-defaults --launch-gui-on-cli-fail
```

The helper attempts CLI slicing first. If the installed GUI build does not expose
a usable CLI slicing path, it opens QIDI Studio and writes settings/step files for
manual confirmation.

## Problem 9: Choosing UI Automation vs noVNC

For Windows desktop apps like QIDI Studio, prefer this order:

1. Native CLI or config files.
2. Windows UI Automation / pywinauto-style control.
3. VNC/noVNC pixel control as a fallback.

Reason: UI Automation can target windows and controls by name. VNC/noVNC is
useful for visibility and fallback clicking, but it is more fragile because it
depends on screen layout and pixels.

Candidate MCP directions:

```text
Windows UI Automation MCP
pywinauto-based MCP
Windows computer-use MCP
VNC/noVNC MCP as fallback
```

## Security Notes

Do not commit:

```text
passwords
private keys
public key bodies
tokens
raw known_hosts contents
API credentials
machine-specific secrets
```

Safe to commit:

```text
alias names
sanitized IP examples
diagnostic flow
service names
firewall rule patterns
paths with no secrets
problem/solution explanations
```
