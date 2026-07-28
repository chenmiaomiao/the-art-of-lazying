# Hackintosh Operations

Reproducible, machine-specific operating notes for unsupported macOS
workstations. Keep serials, ROM values, UUIDs, disk GUIDs, MAC addresses,
private keys, and complete EFI trees outside this public repository.

## Files

- [OptiPlex 3040 Monterey and multi-boot operations](./optiplex-3040-macos-postinstall-and-sequoia-staging.md)
  - establish key-only SSH in both directions;
  - install signed UU Remote, nvm, Node.js, and Codex CLI;
  - enable consented UU control, Apple Remote Management, an auto-fit
    password-only Remmina launcher, bidirectional desktop launchers, and
    never-sleep workstation behavior;
  - keep UU Remote on the visible Aqua console so VNC cannot spawn a competing
    loginwindow agent;
  - repair only the audited Monterey Preboot label from Recovery;
  - promote a backed-up GoldenGate OpenCanopy picker with Monterey, Recovery,
    Windows 10, and legacy Windows 7 discovery;
  - copy and full-hash-verify both NTFS data volumes into named folders;
  - preserve the shrunk NTFS source and stage a separate 200 GiB Apple data
    partition without consuming the reserved 70.6 GiB gap;
  - activate only that audited Apple partition with a guarded macOS helper.
  - reclaim an audited empty SSD spare container, prepare `Sequoia-dev` on the
    SSD, and stage a verified Apple installer plus validated private EFI
    candidate on the 1 TB data disk without starting an upgrade;
  - audit Windows 11 blockers and stage only Microsoft-signed readiness tools
    without running them.

## Boundary

The workflow is portable; an EFI is not. Never copy PlatformInfo identity,
USB maps, ACPI tables, framebuffer properties, or disk identifiers between
machines.
