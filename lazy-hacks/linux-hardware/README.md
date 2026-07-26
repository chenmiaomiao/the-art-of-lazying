# Linux Hardware Notes

Operational notes for workstation hardware that needs small Linux-side fixes.

## Files

- [aic8800dc-usb-wifi-ubuntu-24-04.md](./aic8800dc-usb-wifi-ubuntu-24-04.md)
  - switch the AICsemi dongle from its Windows-driver disk to Wi-Fi mode
  - install a pinned DKMS driver for Ubuntu 24.04 and kernels 6.11/7.0
  - add kernel, header, and boot-time recovery with
    [`aic8800dc-persistence`](./aic8800dc-persistence/)
  - complete Secure Boot MOK enrollment and verify scans, persistence, and rollback
- [usb-camera-rdp-without-logout.md](./usb-camera-rdp-without-logout.md)
  - detect a USB webcam
  - grant immediate RDP-session access without logout/reboot
  - preview the camera with `ffplay`
- [ubuntu-memory-pressure-freeze-prevention.md](./ubuntu-memory-pressure-freeze-prevention.md)
  - diagnose a freeze from retained Gradle and Kotlin memory with `atop`
  - shorten daemon lifetime and cap Kotlin/Gradle concurrency
  - add swap, `systemd-oomd`, and UU service containment without closing
    healthy remote sessions
