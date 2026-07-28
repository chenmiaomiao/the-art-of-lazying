# Hackintosh Operations

Reproducible, machine-specific operating notes for unsupported macOS
workstations. Keep serials, ROM values, UUIDs, disk GUIDs, MAC addresses,
private keys, and complete EFI trees outside this public repository.

## Files

- [OptiPlex 3040 macOS post-install and Sequoia staging](./optiplex-3040-macos-postinstall-and-sequoia-staging.md)
  - establish key-only SSH in both directions;
  - install signed UU Remote, nvm, Node.js, and Codex CLI;
  - enable Apple Remote Management and never-sleep workstation behavior;
  - rename only the installed macOS volume after identity checks;
  - promote a backed-up installed-system OpenCore picker with Windows 10 and
    legacy Windows 7 discovery;
  - download and verify Sequoia without starting the upgrade.

## Boundary

The workflow is portable; an EFI is not. Never copy PlatformInfo identity,
USB maps, ACPI tables, framebuffer properties, or disk identifiers between
machines.
