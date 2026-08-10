# Hackintosh Operations

Reproducible, machine-specific operating notes for unsupported macOS
workstations. Keep serials, ROM values, UUIDs, disk GUIDs, MAC addresses,
private keys, and complete EFI trees outside this public repository.

## Files

- [OptiPlex 3040 Monterey and multi-boot operations](./optiplex-3040-macos-postinstall-and-sequoia-staging.md)
  - establish key-only SSH in both directions;
  - install signed UU Remote, nvm, Node.js, Codex CLI, and the official
    OpenAI-signed Codex desktop app;
  - enable consented UU control, Apple Remote Management, an auto-fit
    password-only Remmina launcher, bidirectional desktop launchers, and
    never-sleep workstation behavior;
  - keep UU Remote on the visible Aqua console so VNC cannot spawn a competing
    loginwindow agent;
  - repair only the audited Monterey Preboot label from Recovery;
  - promote a backed-up GoldenGate OpenCanopy picker with Monterey, Recovery,
    Windows 10, and legacy Windows 7 discovery;
  - audit the later pure-GPT conversion, expose the valid primary Windows 10
    loader, hide its duplicate fallback, and suppress the impossible legacy
    Windows 7 path without editing BCD or partition tables;
  - diagnose the 3040's Kaby-spoofed HD 530 framebuffer hangs, stage a
    separate native-Monterey candidate, recover a failed firmware handoff,
    and remove its test entry while the candidate remains unaccepted;
  - reject the desktop app's high-CPU software-rendering experiment and
    install a verified nvm-based Codex CLI Desktop launcher instead;
  - copy and full-hash-verify both NTFS data volumes into named folders;
  - preserve the shrunk NTFS source and stage a separate 200 GiB Apple data
    partition without consuming the reserved 70.6 GiB gap;
  - activate only that audited Apple partition with a guarded macOS helper.
  - reclaim an audited empty SSD spare container, prepare `Sequoia-dev` on the
    SSD, and stage a verified Apple installer plus validated private EFI
    candidate on the 1 TB data disk without starting an upgrade;
  - audit Windows 11 blockers and stage only Microsoft-signed readiness tools
    without running them.
- [OptiPlex 3040 and 7050 macOS stability](./macos-remote-stability-3040-7050.md)
  - distinguish a crash from an alive but overloaded remote desktop;
  - audit panic, GPU, power, memory, APFS, update, and UU evidence;
  - prevent unattended major macOS updates while retaining security data;
  - deprioritize runaway iCloud and Photos workers without disabling them;
  - start and supervise signed UU Remote jobs after unattended macOS reboots
    without changing account or privacy state;
  - diagnose the 7050 optical SATA fault and stage a guarded SSD TRIM fix;
  - verify Monterey as the 3040's persistent OpenCore default.
- [Intel CoreSimulator GPU-hang safe mode](./intel-coresimulator-gpu-hang-safe-mode.md)
  - distinguish a simulator Metal hang from memory or disk pressure;
  - disable virtual-framebuffer compositing without deleting simulator data;
  - keep archive and store work headless while physical devices provide UI QA.
- [OptiPlex 3040 Windows 7 UEFI and SSH repair](./optiplex-3040-win7-uefi-ssh-repair.md)
  - diagnose GPT conversion damage as unresolved active BCD devices;
  - repair Win7 offline from the stable Win10 control plane with rollback;
  - install pinned Microsoft-signed OpenSSH with key-only LAN access;
  - smoke-test the staged daemon before booting Win7;
  - validate Win7 through disposable firmware and Windows boot sequences;
  - repeat the complete Mac-to-Win7 SSH test without physical console input;
  - reserve UU for bounded reboot recovery rather than primary debugging;
  - return to the unchanged Monterey default and keep the operator-reported
    direct-picker boot separate from the logged acceptance path.

## Boundary

The workflow is portable; an EFI is not. Never copy PlatformInfo identity,
USB maps, ACPI tables, framebuffer properties, or disk identifiers between
machines.
