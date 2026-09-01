# Lazy Hacks

Small, practical workflows and shell tricks that improve daily engineering speed.

## Sections
- [android-file-transfer-reconnect-macos.md](./android-file-transfer-reconnect-macos.md): recover Android File Transfer on macOS after a bad disconnect or “Could not connect to device” popup.
- [baidunetdisk-freeze-fix](./baidunetdisk-freeze-fix/README.md): archived July 2026 notes and non-destructive checks for the exact signed Baidu Netdisk 8.5.8 floating-window right-click deadlock.
- [codex-cli](./codex-cli/README.md): Codex CLI overrides, defaults, and session migration helpers.
- [desktop-tiling](./desktop-tiling/README.md): GNOME desktop tiling workflows, including Tiling Shell.
- [hackintosh](./hackintosh/README.md): machine-specific post-install, multi-boot, remote-access, and staged-upgrade workflows with explicit rollback boundaries.
- [linux-hardware](./linux-hardware/README.md): workstation hardware fixes such as USB webcam access inside RDP, memory-pressure diagnosis, and safe NVIDIA driver refresh without rebooting.
- [linux-shutdown](./linux-shutdown/README.md): systemd ordering and busy-unmount fixes for mounted home subpaths.
- [networking](./networking/README.md): practical home-lab networking notes, including Pi Wi-Fi-to-LAN routing and workstation default-route switching.
- [nutstore-inotify-limit-on-ubuntu.md](./nutstore-inotify-limit-on-ubuntu.md): stop Nutstore's repeated synced-folder-limit popup by fixing inotify instance and watch limits cleanly.
- [remote-desktop](./remote-desktop/README.md): Windows access bootstrapping with RDP/OpenSSH/UU Remote, a Wine-to-GNOME UU control bridge, GNOME automatic-login Desktop Sharing, and native RDP vs XRDP stability notes for Ubuntu 24.04.
- [reload-bashrc-in-open-tmux-panes-safely.md](./reload-bashrc-in-open-tmux-panes-safely.md): validate `.bashrc`, reload only demonstrably idle tmux shells, and avoid disturbing running apps or unfinished commands.
- [storage](./storage/README.md): large-first workstation cleanup, exact Downloads deduplication, and cloud-side iCloud cleanup without materializing the full Drive on a Mac.
- [uuremote-mouse-axis.md](./uuremote-mouse-axis.md): quick fix for GameViewer/UURemote reversed horizontal mouse movement.
- [windows-upgrade](./windows-upgrade/README.md): stage a verified Windows 11 ISO and readiness report on a non-system disk without scheduling or starting Setup.
- [windows-always-on](./windows-always-on/README.md): keep a remote Windows workstation awake and visible, make OS updates manual-only, audit reboot causes, and restore the exact prior state.
- [windows-remote-keyboard-and-ssh.md](./windows-remote-keyboard-and-ssh.md): fix remote Caps Lock desync and set up Windows/Linux OpenSSH in both directions.

## Convention
- Put short, concrete, copy-safe operational tricks here.
- Prefer one topic per file.
- Include exact commands and failure modes.
