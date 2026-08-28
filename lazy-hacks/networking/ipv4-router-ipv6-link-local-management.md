# IPv4 Router With IPv6 Link-Local Management

Use IPv6 link-local access as a management fallback when converting a remotely
managed Linux device from an IPv4 LAN client into an IPv4 router.

This is a useful standard practice for a Raspberry Pi Wi-Fi-to-LAN router:

```text
upstream Wi-Fi
      |
      | wlan0: IPv4 DHCP client and default route
      v
+---------------- Raspberry Pi ----------------+
| IPv4 forwarding and NAT                       |
| eth0 IPv4: static gateway + DHCPv4 server     |
| eth0 IPv6: automatic link-local management    |
+-----------------------------------------------+
      |
      | same Ethernet link
      v
downstream workstation or device
```

The terminology matters: the Ethernet interface is not simultaneously an IPv4
DHCP client and server. Its IPv4 role is a static gateway and DHCPv4 server.
The IPv6 link-local address is assigned automatically by the operating system;
it does not require an IPv6 router or DHCPv6 server.

## Why This Preserves Access

Changing `eth0` from an upstream IPv4 lease such as `192.168.1.x` to a static
downstream address such as `192.168.13.1` immediately breaks the old IPv4 SSH
or VNC session. An existing IPv6 link-local address on `eth0` normally remains
usable because it belongs only to that Ethernet link and does not depend on the
IPv4 address, default gateway, Wi-Fi network, or internet connection.

This provides a recovery path while the router conversion finishes in `tmux`
or a systemd oneshot service. After DHCPv4 is working, normal management moves
to the router's downstream IPv4 address.

## Interface Roles

| Interface and protocol | Standard role |
| --- | --- |
| `wlan0`, IPv4 | Upstream Wi-Fi client; receives the internet route. |
| `eth0`, IPv4 | Static downstream gateway; runs DHCPv4 and DNS for clients. |
| `eth0`, IPv6 link-local | Same-link SSH/VNC recovery path. |

Do not configure `eth0` as an IPv4 DHCP client after enabling its DHCPv4 server.
Do not connect that downstream port to a LAN that already has a DHCP server.

## Record The Recovery Identity First

Before changing IPv4 networking, record the Ethernet MAC address, IPv6
link-local address, and SSH host-key fingerprint from the Pi:

```bash
ip link show dev eth0
ip -6 address show dev eth0 scope link
sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

A link-local address begins with `fe80::`. Keep the SSH host fingerprint in a
trusted local note so the same Pi can be verified after its address changes.
Never copy the private host key.

On Windows, record the interface index of the Ethernet adapter on the same
physical link:

```powershell
Get-NetAdapter -Name 'Ethernet' |
  Select-Object Name, ifIndex, MacAddress, Status
```

Windows appends that interface index as a zone identifier, for example:

```text
fe80::1234:5678:9abc:def0%14
```

The `%14` is required when more than one local interface could reach a
link-local address.

## Verify Before Changing IPv4

From Windows, test the same-link path while the old IPv4 connection still
works:

```powershell
$piLinkLocal = 'fe80::1234:5678:9abc:def0%14'
ping.exe -6 $piLinkLocal
Test-NetConnection -ComputerName $piLinkLocal -Port 22
Test-NetConnection -ComputerName $piLinkLocal -Port 5900
```

Confirm that the SSH key received through the link-local path matches the
fingerprint recorded from the Pi. Do not accept a different key merely because
the IPv4 address has changed.

For OpenSSH, connect with the scoped address:

```powershell
ssh "pi@$piLinkLocal"
```

For a VNC application, use its bracketed IPv6 form when required:

```text
[fe80::1234:5678:9abc:def0%14]
```

Do not place SSH or VNC passwords on the command line.

## Safe Router Conversion Workflow

1. Confirm the Wi-Fi uplink has an address, default route, DNS, and HTTPS access.
2. Remove saved Wi-Fi profiles that the router must never select automatically.
3. Record and test the Ethernet IPv6 link-local management path.
4. Back up network, DHCP/DNS, firewall, sysctl, and service configuration.
5. Start the idempotent conversion in `tmux` or a systemd oneshot service.
6. Assign the static IPv4 gateway to `eth0`; remove its old IPv4 DHCP route.
7. Enable DHCPv4/DNS only after `eth0` is isolated from the previous LAN.
8. Reconnect through IPv6 link-local and verify the router-side state.
9. Attach a real downstream client and confirm DHCP, DNS, HTTPS, and NAT traffic.
10. Use the stable downstream IPv4 gateway address for routine management.

The router-side checks should include:

```bash
ip -brief address show dev wlan0
ip -brief address show dev eth0
ip -4 route
sysctl net.ipv4.ip_forward
systemctl is-active dnsmasq
sudo iptables -S FORWARD
sudo iptables -t nat -S POSTROUTING
```

A real downstream test is still required. Seeing the gateway address on the Pi
does not prove that a client received DHCP or traversed NAT.

## Security And Operational Limits

- IPv6 link-local is not internet-routable, but any device on the same Ethernet
  segment may attempt to reach it. Keep SSH/VNC authentication enabled.
- Link-local addressing does not provide encryption. Rely on SSH and the VNC
  transport's authenticated encryption.
- Pin the server's host key or certificate before the IPv4 migration.
- Restrict management services with a host firewall when the downstream LAN is
  not fully trusted.
- The fallback stops working when the Ethernet carrier is down or the
  workstation is moved to another layer-2 segment.
- The zone identifier can change when a USB adapter is removed or reinserted.
- A MAC-address or privacy-setting change can produce a different link-local
  address; rediscover it from a trusted console or neighbor table.
- Campus Wi-Fi client isolation does not affect same-link Ethernet IPv6 access.
- Never treat this fallback as permission to run two DHCPv4 servers on the same
  LAN. Physically isolate the downstream segment before enabling DHCP.

## Standard Completion Checklist

- [ ] Upstream Wi-Fi is the only IPv4 default route.
- [ ] Downstream Ethernet has a static IPv4 gateway address.
- [ ] Downstream Ethernet is not an IPv4 DHCP client.
- [ ] DHCPv4 listens only on the downstream interface.
- [ ] IPv4 forwarding and one idempotent NAT rule set are active.
- [ ] IPv6 link-local SSH/VNC was tested with a pinned host identity.
- [ ] A real downstream client received a lease and generated bidirectional NAT traffic.
- [ ] Normal management works through the downstream IPv4 gateway.
- [ ] Backups and a rollback command are documented.

This fallback complements the main
[Raspberry Pi Wi-Fi To LAN Router](./pi-wifi-to-lan-router.md) procedure; it does
not replace downstream isolation, persistence checks, or client-side testing.
