# childwaf

Modular internet filter for children's devices on **Devuan Linux** (sysvinit).

Combines `iptables`, `ipset`, and `dnsmasq` to enforce:

- **Per-child access policies** – each device gets its own rule set
- **Time-based schedules** – internet allowed only during configured hours
- **Category-based domain blocking** – uses dnsmasq + ipset for efficient filtering
- **Bypass prevention** – blocks external DNS, DNS-over-TLS, DNS-over-HTTPS, and common VPN ports

---

## How it works

```
Child device                Gateway (Devuan)              Internet
     │                           │
     │  DNS query (port 53) ─────▶  dnsmasq
     │                           │   • blocked domain? → NXDOMAIN
     │                           │   • resolved IP added to category ipset
     │                           │
     │  TCP/UDP to internet ─────▶  iptables FORWARD
     │                           │   └─▶ CHILDWAF_FILTER
     │                           │         └─▶ CHILDWAF_C_<child>
     │                           │               • ESTABLISHED → RETURN
     │                           │               • category ipset match → DROP
     │                           │               • VPN/DoT/DoH ports → DROP
     │                           │               • outside schedule → DROP
     │                           │               • within schedule → ACCEPT
     │                           │                                        │
     │  ◀────────────────────────────────────────────────────────────────▶
```

Children who manually configure an external DNS server (8.8.8.8 etc.) are handled by a NAT PREROUTING rule that transparently redirects their DNS queries back to the local dnsmasq.

---

## Installation

```bash
git clone <repo-url>
cd childwaf-
sudo ./install.sh
```

### Requirements

| Package | Purpose |
|---------|---------|
| `iptables` | Packet filtering and NAT |
| `ipset` | Efficient IP set matching |
| `dnsmasq` | DNS filtering and ipset population |

Install on Devuan / Debian:
```bash
apt-get install iptables ipset dnsmasq
```

---

## Quick start

**1. Edit main config**
```bash
nano /etc/childwaf/childwaf.conf
```
Set `LAN_INTERFACE` (e.g. `eth0`) and `WAN_INTERFACE` (e.g. `eth1`).

**2. Create a child profile**
```bash
cp /etc/childwaf/children/example.conf /etc/childwaf/children/alice.conf
nano /etc/childwaf/children/alice.conf
```

Minimum required settings:
```ini
NAME="Alice"
IP=192.168.1.100          # child's device IP (use DHCP static lease)
BLOCK_CATEGORIES="adult social-media gaming"
SCHEDULE_MON=15:00-20:00
# ... (set all 7 days)
```

**3. Apply the rules**
```bash
childwaf start
```

**4. Check status**
```bash
childwaf status
childwaf check     # verify dependencies
```

---

## Configuration reference

### Main config (`/etc/childwaf/childwaf.conf`)

| Setting | Default | Description |
|---------|---------|-------------|
| `LAN_INTERFACE` | `eth0` | Interface facing children's devices |
| `WAN_INTERFACE` | `eth1` | Internet-facing interface |
| `MODULE_DNS` | `yes` | Enable dnsmasq-based domain filtering |
| `MODULE_IPTABLES` | `yes` | Enable iptables rules |
| `MODULE_SCHEDULE` | `yes` | Enable time-based schedule |
| `DNS_LOCAL_PORT` | `53` | Port of local filtering dnsmasq |
| `DNS_REDIRECT_CHILDREN` | `yes` | Force children's DNS through local dnsmasq |
| `DNS_BLOCK_BYPASS` | `yes` | Block DoT (853), external DNS forwarding |

### Child profile (`/etc/childwaf/children/<name>.conf`)

| Setting | Example | Description |
|---------|---------|-------------|
| `NAME` | `"Alice"` | Display name (used in logs) |
| `IP` | `192.168.1.100` | Device IP(s), space-separated, CIDR ok |
| `BLOCK_CATEGORIES` | `"adult social-media"` | Space-separated category names |
| `BLOCK_DOMAINS` | `"game.io chat.app"` | Additional hard-blocked domains |
| `DNS_FILTER` | `yes` | Enable DNS filtering for this child |
| `SCHEDULE_ENABLED` | `yes` | Enable schedule for this child |
| `SCHEDULE_MON` … `SCHEDULE_SUN` | `15:00-20:00` | Allowed hours per day |

Schedule values: `HH:MM-HH:MM` · `always` · `never`

### Blocklist categories

| File | Description |
|------|-------------|
| `adult.list` | Adult / explicit content |
| `social-media.list` | Social networks and messaging |
| `gaming.list` | Online gaming platforms |
| `streaming.list` | Video and music streaming |
| `doh-providers.list` | DNS-over-HTTPS provider IPs (CIDR ranges) |
| `custom.list` | Your own additions |

Add or edit domains in `/etc/childwaf/blocklists/*.list`, then run `childwaf reload`.

---

## Multiple children

Create one `.conf` file per child. Each child gets:
- An `ipset` (`childwaf_child_<name>`) containing their device IP(s)
- A dedicated iptables chain (`CHILDWAF_C_<name>`) with their own rules
- Independent schedule, categories, and blocked domains

```bash
cp /etc/childwaf/children/example.conf /etc/childwaf/children/bob.conf
nano /etc/childwaf/children/bob.conf
childwaf reload
```

---

## Operations

```bash
childwaf start    # Apply all rules (done automatically at boot via init.d)
childwaf stop     # Remove all rules (full internet access restored)
childwaf restart  # Stop + start
childwaf reload   # Regenerate config and rules (no traffic interruption)
childwaf status   # Show active children, chains, and ipsets
childwaf check    # Verify system dependencies
```

Via init.d (Devuan sysvinit):
```bash
service childwaf start
service childwaf reload
```

---

## Bypass prevention

childwaf blocks the following bypass techniques:

| Technique | How blocked |
|-----------|-------------|
| External DNS (8.8.8.8) | NAT redirect to local dnsmasq |
| DNS-over-TLS (port 853) | iptables DROP |
| DNS-over-HTTPS | iptables DROP to known DoH provider IPs (`doh-providers.list`) |
| OpenVPN (1194) | iptables DROP |
| WireGuard (51820) | iptables DROP |
| IPsec/IKE (500, 4500) | iptables DROP |

> **Note**: blocking DoH completely requires that all traffic to known DoH provider IPs is blocked. Keep `doh-providers.list` updated as providers add IP ranges.

---

## Recommended upstream DNS

For additional filtering at the resolver level, configure dnsmasq to use a family-safe upstream:

```
# /etc/dnsmasq.d/upstream.conf
server=1.1.1.3        # Cloudflare for Families (blocks malware + adult)
server=1.0.0.3
```

Options:
- **Cloudflare for Families**: `1.1.1.3` / `1.0.0.3`
- **CleanBrowsing Family**: `185.228.168.168` / `185.228.169.168`
- **OpenDNS FamilyShield**: `208.67.222.123` / `208.67.220.123`
- **DNS0 Kids** (EU): `35.196.37.78`

---

## License

GNU General Public License v3 – see [LICENSE](LICENSE).
