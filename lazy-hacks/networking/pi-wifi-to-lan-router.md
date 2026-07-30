# Raspberry Pi Wi-Fi To LAN Router

This note documents a Raspberry Pi setup that takes an upstream Wi-Fi connection and shares it to wired Ethernet clients through NAT.

Despite some script names using "bridge", this is not a true layer-2 bridge. It is a small Linux router:

```text
upstream Wi-Fi -> wlan0 -> NAT -> eth0 -> downstream LAN
```

## Runtime Shape

The expected shape is:

```text
wlan0: upstream Wi-Fi, receives DHCP/default route from the Wi-Fi network
eth0:  static LAN gateway, for example 192.168.2.1/24
dnsmasq: DHCP server for eth0 clients
iptables/nftables: NAT masquerade out wlan0
net.ipv4.ip_forward: 1
```

Traffic flow:

1. A downstream device plugs into the Pi's Ethernet side.
2. `dnsmasq` leases it an address such as `192.168.2.159`.
3. That client uses the Pi as its gateway.
4. The Pi forwards packets from `eth0` to `wlan0`.
5. NAT masquerade rewrites traffic so it can leave through the upstream Wi-Fi.

## Confirmed Stable Snapshot

This is the confirmed stable shape from a working Pi. It is a useful target
state for another Pi without publishing device identity or upstream-network
details.

```text
upstream interface: wlan0
downstream interface: eth0
eth0: 192.168.2.1/24
wlan0: DHCP address from upstream Wi-Fi
default route: via upstream Wi-Fi gateway on wlan0
dnsmasq: active and enabled
netfilter-persistent: enabled
networking.service: masked
pi-wifi-to-lan-router-fix.service: enabled oneshot
pi-router-health-monitor.service: inactive/not installed as an active unit
```

The live status matched:

```text
net.ipv4.ip_forward = 1
net.ipv4.ip_default_ttl = 65
NetworkManager Wi-Fi powersave = disable
runtime power control = on
driver Wi-Fi power save = off
```

The final saved firewall state should be exactly:

```text
MANGLE:
-A POSTROUTING -o wlan0 -j TTL --ttl-set 65

FILTER:
-A FORWARD -i eth0 -o wlan0 -j ACCEPT
-A FORWARD -i wlan0 -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT

NAT:
-A POSTROUTING -o wlan0 -j MASQUERADE
```

There should not be duplicate `MASQUERADE`, duplicate `FORWARD`, or duplicate TTL rules.

The current Pi has two historical sysctl files:

```text
/etc/sysctl.d/99-wifi-lan-router.conf      -> ip_forward + default_ttl
/etc/sysctl.d/99-wifi-to-lan-router.conf   -> ip_forward only
```

That split is harmless because both set `ip_forward=1`, but for a new Pi use one clean file only:

```text
/etc/sysctl.d/99-wifi-lan-router.conf
```

## Current Active Script

Install the active helper at a system-owned path:

```text
/usr/local/sbin/pi-wifi-to-lan-router-fix.sh
```

It is installed as a boot-time oneshot service:

```ini
[Unit]
Description=Ensure Raspberry Pi Wi-Fi-to-LAN router settings
Documentation=file:/usr/local/sbin/pi-wifi-to-lan-router-fix.sh
Wants=network-online.target
After=NetworkManager.service dnsmasq.service network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pi-wifi-to-lan-router-fix.sh apply
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

The important design choice is that this is not a loop. It runs once at boot, makes the router state correct, and exits.

The reusable repo version is:

```text
lazy-hacks/networking/pi-wifi-to-lan-router-fix.sh
```

The inspected live script is the stable base, but TTL was added later as a separate manual step. The repo version folds that later TTL fix into the script itself, so a new Pi does not need separate manual TTL commands after the boot service is installed.

Use the repo version for a new Pi. Do not copy the current Pi's historical two-file sysctl split as a pattern.

## Apply To Another Pi

Copy the script to the target Pi:

```bash
scp lazy-hacks/networking/pi-wifi-to-lan-router-fix.sh \
  <remote-user>@<router-address>:/tmp/pi-wifi-to-lan-router-fix.sh
```

Install it:

```bash
ssh <remote-user>@<router-address>
sudo install -D -o root -g root -m 0755 \
  /tmp/pi-wifi-to-lan-router-fix.sh \
  /usr/local/sbin/pi-wifi-to-lan-router-fix.sh
```

Create the oneshot service:

```bash
sudo tee /etc/systemd/system/pi-wifi-to-lan-router-fix.service >/dev/null <<'EOF'
[Unit]
Description=Ensure Raspberry Pi Wi-Fi-to-LAN router settings
Documentation=file:/usr/local/sbin/pi-wifi-to-lan-router-fix.sh
Wants=network-online.target
After=NetworkManager.service dnsmasq.service network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pi-wifi-to-lan-router-fix.sh apply
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
```

Run once manually first:

```bash
sudo /usr/local/sbin/pi-wifi-to-lan-router-fix.sh status
sudo /usr/local/sbin/pi-wifi-to-lan-router-fix.sh apply
```

If the upstream Wi-Fi connection name differs from the script default, override
it:

```bash
sudo UPSTREAM_CONN='<upstream-connection>' \
  /usr/local/sbin/pi-wifi-to-lan-router-fix.sh apply
```

If the interface names differ:

```bash
sudo UPSTREAM_CONN='<upstream-connection>' WAN_IF=wlan0 LAN_IF=eth0 \
  /usr/local/sbin/pi-wifi-to-lan-router-fix.sh apply
```

Enable at boot only after manual `apply` succeeds:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now pi-wifi-to-lan-router-fix.service
sudo systemctl status pi-wifi-to-lan-router-fix.service --no-pager
```

Expected status is `active (exited)`, not a long-running process.

## Failure Mode Seen

The Pi had a long-running uptime and then became unreachable or appeared frozen after several days.

Important evidence:

- no logged kernel panic
- no OOM kill
- no EXT4 or SD-card I/O error
- no thermal shutdown
- no undervoltage/throttling flag at inspection time
- journal from the previous boot was marked unclean after reboot
- final useful logs before reboot were Wi-Fi/DHCP/NTP related

This pattern suggests the first failure was likely upstream Wi-Fi/internet interruption, followed by a hard reset or unlogged lock.

For an always-on router, two weak points matter most:

- Enterprise or campus Wi-Fi can force roaming, reauthentication, and DHCP renewal.
- Wi-Fi power saving can make an always-on forwarding path less reliable.

## Lessons Learned

The first stabilization attempt became too complicated. Repeated monitoring and restart loops can make a small router less reliable because they keep touching exactly the fragile parts:

- Wi-Fi reconnect
- `dnsmasq` restart
- firewall reload
- route state
- logging every minute

The better stable pattern is:

- one clean boot-time apply
- no active repair loop by default
- no repeated Wi-Fi restart unless requested manually
- no duplicate iptables rules
- no repeated `apt update` or package install as part of normal repair
- no periodic log spam on the SD card
- use `status` for diagnosis, not a permanent watcher

An old diagnostic monitor may be useful for a temporary investigation:

```text
<temporary-work-directory>/pi-router-health-monitor.sh
```

But it should stay disabled unless actively debugging an outage. It loops forever, writes `/var/log/pi-router-health.log`, and pings every 60 seconds. That is useful evidence collection, not the normal stable operating mode.

## First Stabilization Steps

Disable Wi-Fi powersave for the upstream NetworkManager connection:

```bash
upstream_connection='<upstream-connection>'
sudo nmcli connection modify "$upstream_connection" \
  802-11-wireless.powersave 2
sudo iw dev wlan0 set power_save off
```

The NetworkManager change persists for the next activation, while `iw` changes
the current runtime state without deliberately dropping the remote session.

Clean and persist a single NAT rule set:

```bash
sudo iptables -F FORWARD
sudo iptables -t nat -F POSTROUTING

sudo iptables -A FORWARD -i eth0 -o wlan0 -j ACCEPT
sudo iptables -A FORWARD -i wlan0 -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo iptables -t nat -A POSTROUTING -o wlan0 -j MASQUERADE

sudo netfilter-persistent save
```

Then consider adding a small systemd watchdog that pings the upstream gateway and restarts the Wi-Fi connection plus `dnsmasq` if forwarding breaks.

## Applied Fix Result

After running the safe apply mode, the intended final state is:

```text
net.ipv4.ip_forward: 1
Wi-Fi powersave: disabled for the upstream NetworkManager connection
eth0: static LAN gateway, 192.168.2.1/24
wlan0: upstream Wi-Fi, DHCP/default route from the Wi-Fi network
dnsmasq: active and enabled
```

The firewall should have one clean forwarding and NAT rule set:

```text
FORWARD:
-A FORWARD -i eth0 -o wlan0 -j ACCEPT
-A FORWARD -i wlan0 -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT

NAT POSTROUTING:
-A POSTROUTING -o wlan0 -j MASQUERADE
```

Verification should include:

```bash
upstream_connection='<upstream-connection>'
cat /proc/sys/net/ipv4/ip_forward
nmcli -f 802-11-wireless.powersave connection show "$upstream_connection"
ip -brief addr show eth0
ip -brief addr show wlan0
systemctl is-active dnsmasq
sudo iptables -S FORWARD
sudo iptables -t nat -S POSTROUTING
upstream_gateway=$(ip -4 route show default dev wlan0 | awk 'NR == 1 {print $3}')
test -n "$upstream_gateway"
ping -c 2 "$upstream_gateway"
getent ahostsv4 example.com
```

If those checks match the shape above, the fix does not need to be rerun.

One display-only bug was also fixed in the helper script: the status command should query `eth0` and `wlan0` separately instead of passing both interface names to one `ip -brief addr show` call.

## TTL 65 Setting

Some upstream networks identify tethered or routed traffic by seeing that packets arrive with a lower TTL than traffic originating from the router itself. For a Pi used as a Wi-Fi-to-LAN NAT router, one practical mitigation is:

```text
default host TTL: 65
outbound forwarded packets on wlan0: force TTL to 65
```

Use a dedicated sysctl file instead of editing the large default `/etc/sysctl.conf`:

```bash
sudo install -d -m 0755 /etc/sysctl.d
printf '%s\n' \
  'net.ipv4.ip_forward=1' \
  'net.ipv4.ip_default_ttl=65' \
  | sudo tee /etc/sysctl.d/99-wifi-lan-router.conf >/dev/null

sudo sysctl -w net.ipv4.ip_forward=1 net.ipv4.ip_default_ttl=65
```

Then make the mangle rule idempotent and scoped to the upstream Wi-Fi interface:

```bash
while sudo iptables -t mangle -D POSTROUTING -j TTL --ttl-set 65 2>/dev/null; do
  echo 'removed broad TTL POSTROUTING rule'
done

while sudo iptables -t mangle -D POSTROUTING -o wlan0 -j TTL --ttl-set 65 2>/dev/null; do
  echo 'removed duplicate scoped TTL POSTROUTING rule'
done

sudo iptables -t mangle -A POSTROUTING -o wlan0 -j TTL --ttl-set 65
sudo netfilter-persistent save
```

The final rule should be exactly one scoped rule:

```text
-A POSTROUTING -o wlan0 -j TTL --ttl-set 65
```

Verification:

```bash
sysctl net.ipv4.ip_forward net.ipv4.ip_default_ttl
sudo iptables-save -t mangle | sed -n '/\*mangle/,/COMMIT/p'
sudo iptables-save -t nat | sed -n '/\*nat/,/COMMIT/p'
ip -brief addr show dev wlan0
ip -brief addr show dev eth0
ip route
ping -c 2 8.8.8.8
getent hosts google.com
```

## Two Pis With The Same LAN IP

Two Pi routers can use the same downstream address only when the workstation
reaches them through genuinely separate paths. Source binding helps select a
path, but it does not make an ambiguous routing table safe.

Use placeholders for the private values:

| Placeholder | Meaning |
| --- | --- |
| `<shared-router-ip>` | Address used by both routers on their separate downstream networks. |
| `<source-address-a>` | Workstation address whose route reaches router A. |
| `<source-address-b>` | Workstation address whose route reaches router B. |
| `<remote-user>` | Administrative account on the Pis. |
| `<path-a-private-key>` | Local private-key filename for path A. |
| `<path-b-private-key>` | Local private-key filename for path B. |

Do not put real hostnames, SSIDs, machine IDs, source addresses, key names, or
host-key bodies in a shared note.

### Pin Each Host Key Before Connecting

Do not use `StrictHostKeyChecking=accept-new` for same-address devices. An
unexpected device on either path could otherwise be trusted automatically.

At each Pi's local console, display its Ed25519 host public key and fingerprint:

```bash
sudo cat /etc/ssh/ssh_host_ed25519_key.pub
sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Carry the public key and fingerprint to the workstation through a trusted,
out-of-band path. Never copy
`/etc/ssh/ssh_host_ed25519_key`, which is the private host key.

Create a dedicated known-hosts entry whose first field matches the alias that
will be used by `HostKeyAlias`. For example, in PowerShell:

```powershell
$knownHosts = "$HOME\.ssh\pi-router-path-a-known_hosts"
'pi-router-path-a ssh-ed25519 <verified-host-public-key-a>' |
  Set-Content -Encoding ascii $knownHosts
ssh-keygen -lf $knownHosts
```

Compare the displayed fingerprint with the one read at the Pi console. Stop if
they differ. Repeat with a separate file and verified key for path B.

### Use Source-Bound SSH Aliases

Add entries like these to the workstation's OpenSSH config after replacing every
placeholder:

```sshconfig
Host pi-router-path-a
    HostName <shared-router-ip>
    User <remote-user>
    BindAddress <source-address-a>
    HostKeyAlias pi-router-path-a
    UserKnownHostsFile ~/.ssh/pi-router-path-a-known_hosts
    IdentityFile ~/.ssh/<path-a-private-key>
    IdentitiesOnly yes
    StrictHostKeyChecking yes

Host pi-router-path-b
    HostName <shared-router-ip>
    User <remote-user>
    BindAddress <source-address-b>
    HostKeyAlias pi-router-path-b
    UserKnownHostsFile ~/.ssh/pi-router-path-b-known_hosts
    IdentityFile ~/.ssh/<path-b-private-key>
    IdentitiesOnly yes
    StrictHostKeyChecking yes
```

Before connecting, verify that each source address is currently assigned to the
expected workstation interface and that the OS selects the intended path.

On Linux:

```bash
ip -brief address
ip route get <shared-router-ip> from <source-address-a>
ip route get <shared-router-ip> from <source-address-b>
```

On Windows:

```powershell
Get-NetIPAddress -AddressFamily IPv4
Get-NetRoute -AddressFamily IPv4 |
  Sort-Object DestinationPrefix, RouteMetric
ssh -G pi-router-path-a |
  Select-String 'hostname|bindaddress|hostkeyalias|userknownhostsfile'
ssh -G pi-router-path-b |
  Select-String 'hostname|bindaddress|hostkeyalias|userknownhostsfile'
```

If either route is ambiguous, fix the interface or route configuration before
opening SSH. Do not test a repair by connecting to the raw shared address.

Connect only through the aliases:

```powershell
ssh pi-router-path-a
ssh pi-router-path-b
```

After login, confirm the physical device using an inventory label or a console
record, then inspect its network role:

```bash
ip -brief address
ip route
nmcli -t -f NAME,DEVICE,TYPE connection show --active
sudo /usr/local/sbin/pi-wifi-to-lan-router-fix.sh status
```

Do not publish the command output when it contains device identity or upstream
network details.

### Apply Per-Router Settings Safely

Run `status` first. For a manual apply, pass the router-specific connection and
interface names without changing Wi-Fi connectivity during the remote session:

```bash
sudo env \
  UPSTREAM_CONN='<upstream-connection>' \
  WAN_IF='<upstream-interface>' \
  LAN_IF='<downstream-interface>' \
  /usr/local/sbin/pi-wifi-to-lan-router-fix.sh apply
```

Do not request a Wi-Fi reconnect on the first remote apply. Confirm success
before enabling the boot service.

If the base unit already contains `Type`, `ExecStart`, and `RemainAfterExit`,
its drop-in should override only environment values:

```bash
sudo systemctl edit pi-wifi-to-lan-router-fix.service
```

```ini
[Service]
Environment="UPSTREAM_CONN=<upstream-connection>"
Environment="WAN_IF=<upstream-interface>"
Environment="LAN_IF=<downstream-interface>"
```

Do not repeat `ExecStart` in the drop-in. Review the complete merged unit and
make sure it still has exactly one `ExecStart`:

```bash
sudo systemctl daemon-reload
sudo systemctl cat pi-wifi-to-lan-router-fix.service
sudo systemctl enable --now pi-wifi-to-lan-router-fix.service
sudo systemctl status pi-wifi-to-lan-router-fix.service --no-pager
```

Expected status is `active (exited)`. The helper is an idempotent oneshot, not a
polling daemon.

### Verify Both Sides

On the Pi, test only its upstream path first:

```bash
upstream_interface='<upstream-interface>'
upstream_gateway=$(
  ip -4 route show default dev "$upstream_interface" |
    awk 'NR == 1 {print $3}'
)
test -n "$upstream_gateway"
ping -c 2 "$upstream_gateway"
getent ahostsv4 example.com
```

Then test forwarding from a client physically attached to that Pi's downstream
LAN:

```text
1. Confirm the client received an address and default route from the Pi.
2. Ping <shared-router-ip>.
3. Ping <known-public-test-address>.
4. Resolve example.com using <shared-router-ip> as the DNS server.
5. Open an HTTPS site allowed by the upstream network.
```

Repeating `ping <shared-router-ip>` on the Pi itself proves only its own local
address exists; it does not test downstream forwarding. Repeat the downstream
client checks for the other Pi through its physically separate LAN.

The stable firewall shape on each router is one forward rule in each direction,
one upstream `MASQUERADE` rule, and one scoped TTL rule. Run the helper's
`status` action again and verify no duplicate rules appeared.

If package work fails with `Bus error` and the kernel reports SD-card I/O
errors, stop broad upgrades. Follow
[Raspberry Pi SD-Card I/O Failure: Temporary Apt Recovery](./pi-sd-bad-sector-apt-repair.md);
image and replace the card before attempting live mutation whenever possible.

## Confirmed Script Flaw

The old `bridge_final.sh` works for first-time setup, but it has a real idempotency flaw:

```bash
iptables -t nat -A POSTROUTING -o wlan0 -j MASQUERADE
```

Every install run appends another matching NAT rule. That is why duplicate `MASQUERADE` entries can appear after running the script more than once.

The uninstall path also removes only one matching rule:

```bash
iptables -t nat -D POSTROUTING -o wlan0 -j MASQUERADE || true
```

So if two or more duplicate rules exist, one uninstall run leaves extras behind. The corrected pattern is to delete all matching copies first, then add exactly one rule:

```bash
iptables_rule_exists() {
  local table="$1"
  shift
  if [ -n "$table" ]; then
    iptables -t "$table" -C "$@" >/dev/null 2>&1
  else
    iptables -C "$@" >/dev/null 2>&1
  fi
}

iptables_delete_rule() {
  local table="$1"
  shift
  if [ -n "$table" ]; then
    iptables -t "$table" -D "$@"
  else
    iptables -D "$@"
  fi
}

iptables_add_rule() {
  local table="$1"
  shift
  if [ -n "$table" ]; then
    iptables -t "$table" -A "$@"
  else
    iptables -A "$@"
  fi
}

iptables_ensure_one() {
  local table="$1"
  shift
  while iptables_rule_exists "$table" "$@"; do
    iptables_delete_rule "$table" "$@"
  done
  iptables_add_rule "$table" "$@"
}

iptables_ensure_one "" FORWARD -i eth0 -o wlan0 -j ACCEPT
iptables_ensure_one "" FORWARD -i wlan0 -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables_ensure_one nat POSTROUTING -o wlan0 -j MASQUERADE
netfilter-persistent save
```

For the live Pi, the safer helper is the idempotent repair script:

```bash
sudo /usr/local/sbin/pi-wifi-to-lan-router-fix.sh apply
```

Do not use the old install mode repeatedly as a repair command unless it has been hardened with the idempotent rule pattern above.

## Legacy Full Script

This is the observed legacy script. It installs and uninstalls the Wi-Fi-to-LAN NAT router setup, but it is kept here as a reference rather than as the recommended repair path.

```bash
#!/usr/bin/env bash

set -e

[ $EUID -ne 0 ] && echo "Please run as root" >&2 && exit 1

# Function to display usage
usage() {
    echo "Usage: $0 -i | -u"
    echo "  -i    Install bridge configuration"
    echo "  -u    Uninstall bridge configuration"
    exit 1
}

# Check for exactly one argument
if [ "$#" -ne 1 ]; then
    usage
fi

case "$1" in
    -i)
        # Install steps
        echo "Installing bridge configuration..."

        # Update system and install required packages
        apt update && \
        DEBIAN_FRONTEND=noninteractive apt install -y \
            dnsmasq netfilter-persistent iptables-persistent

        # Create and persist iptables rule
        iptables -t nat -A POSTROUTING -o wlan0 -j MASQUERADE
        netfilter-persistent save

        # Enable IPv4 forwarding
        sed -i.bak 's/#*net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
        sysctl -p /etc/sysctl.conf

        # Configure eth0 with a static IP address
        cat <<'EOF' >/etc/network/interfaces.d/eth0
auto eth0
allow-hotplug eth0
iface eth0 inet static
  address 192.168.2.1
  netmask 255.255.255.0
EOF

        # Create dnsmasq DHCP configuration
        cat <<'EOF' >/etc/dnsmasq.d/bridge.conf
interface=eth0
bind-interfaces
server=8.8.8.8
domain-needed
bogus-priv
dhcp-range=192.168.2.2,192.168.2.254,12h
EOF

        # Restart dnsmasq to apply the new configuration
        systemctl restart dnsmasq
        systemctl enable dnsmasq

        # Mask networking.service to prevent conflicts
        systemctl mask networking.service

        echo "Installation complete. Your Raspberry Pi is now configured as a WiFi to Ethernet bridge."
        ;;
    -u)
        # Uninstall steps
        echo "Uninstalling bridge configuration..."

        # Remove the iptables rule
        iptables -t nat -D POSTROUTING -o wlan0 -j MASQUERADE || true
        netfilter-persistent save

        # Restore original sysctl.conf if backup exists
        if [ -f /etc/sysctl.conf.bak ]; then
            mv /etc/sysctl.conf.bak /etc/sysctl.conf
        else
            # Comment out net.ipv4.ip_forward=1 if backup not found
            sed -i 's/^net.ipv4.ip_forward=1/#net.ipv4.ip_forward=1/' /etc/sysctl.conf
        fi
        sysctl -p /etc/sysctl.conf

        # Remove the static IP configuration for eth0
        rm -f /etc/network/interfaces.d/eth0

        # Remove dnsmasq configuration
        rm -f /etc/dnsmasq.d/bridge.conf

        # Restart dnsmasq to apply changes
        systemctl restart dnsmasq

        # Unmask networking.service
        systemctl unmask networking.service

        echo "Uninstallation complete. The bridge configuration has been removed."
        ;;
    *)
        # Invalid option
        usage
        ;;
esac
```

## Script Logic

Install:

```bash
sudo ./bridge_final.sh -i
```

What it does:

1. Installs `dnsmasq`, `netfilter-persistent`, and `iptables-persistent`.
2. Adds NAT masquerade on outbound `wlan0`.
3. Saves netfilter rules.
4. Enables IPv4 forwarding in `/etc/sysctl.conf`.
5. Configures `eth0` with static `192.168.2.1/24`.
6. Configures `dnsmasq` to serve `192.168.2.2` through `192.168.2.254`.
7. Restarts and enables `dnsmasq`.
8. Masks `networking.service`.

Uninstall:

```bash
sudo ./bridge_final.sh -u
```

What it does:

1. Deletes one NAT masquerade rule.
2. Saves netfilter rules.
3. Restores or disables IPv4 forwarding.
4. Removes the static `eth0` config.
5. Removes the `dnsmasq` bridge config.
6. Restarts `dnsmasq`.
7. Unmasks `networking.service`.

## Caveats

The script is useful, but it is not idempotent:

- repeated install appends duplicate `MASQUERADE` rules
- uninstall removes only one matching NAT rule
- it edits `/etc/sysctl.conf` directly
- it calls `apt update` during setup
- it does not disable Wi-Fi powersave
- it has no watchdog for upstream Wi-Fi failure

A hardened version should use `iptables -C` before adding rules, clean duplicates before saving, write a dedicated `/etc/sysctl.d/*.conf`, disable Wi-Fi powersave, and run a health watchdog for the upstream link.
