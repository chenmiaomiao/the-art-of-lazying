# Networking

Practical small-networking notes for workstation and home-lab reliability.

## Notes

- [Astrill Lazy Router Native Windows Setup](./astrill-lazy-router-native-windows.md):
  build, key onboarding, Ubuntu-aligned Windows controls, persistent-core and
  source-scoped RAM-overlay policy storage, bounded atomic overlay loading,
  physical-reboot/one-shot recovery, and measured E4200 validation.
- [Raspberry Pi Wi-Fi To LAN Router](./pi-wifi-to-lan-router.md): a Raspberry Pi NAT router pattern using `wlan0`, `eth0`, `dnsmasq`, IPv4 forwarding, and masquerade rules.
- [IPv4 Router With IPv6 Link-Local Management](./ipv4-router-ipv6-link-local-management.md): preserve same-link SSH/VNC access while an Ethernet port changes from an IPv4 client into a downstream gateway and DHCP server.
- [Raspberry Pi SD-Card I/O Failure: Temporary Apt Recovery](./pi-sd-bad-sector-apt-repair.md): image-and-replace-first guidance for storage-backed `ldconfig` and `dpkg` failures, with tightly bounded live recovery as a last resort.
- [Workstation Internet Route Switcher](./workstation-internet-route-switcher.md): a small `netswitch` CLI and GNOME launcher for choosing wired or Wi-Fi as the workstation default route.

## Reusable Scripts

- [pi-wifi-to-lan-router-fix.sh](./pi-wifi-to-lan-router-fix.sh): hardened boot-time/manual repair script for another Pi, including Wi-Fi powersave disablement, clean NAT/FORWARD rules, TTL 65, dnsmasq refresh, and status checks.
