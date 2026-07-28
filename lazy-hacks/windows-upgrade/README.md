# Windows Upgrade Staging

Prepare Windows upgrade media and machine reports without starting an
upgrade.

## Files

- [OptiPlex 3040 Windows 11 25H2 staging](./optiplex-3040-windows11-25h2-staging.md)
  - audit the installed Windows 10 system and multi-boot disks;
  - place the ISO and reports on the separate 1 TB data disk;
  - verify a Microsoft-published SHA-256 value;
  - prove that no upgrade launch or persistence mechanism was created;
  - keep the future unsupported-hardware decision explicit and attended.

## Boundary

Staging is not installation. The preparation scripts do not mount an ISO,
run `setup.exe`, create a scheduled task, write `Run` or `RunOnce`, alter BCD
or UEFI variables, or ask Windows Update to target Windows 11.
