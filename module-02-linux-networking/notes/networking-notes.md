# Networking Notes — Module 02

## IP addressing
- An **IPv4 address** is 4 numbers (0–255): `172.31.24.10`.
- **CIDR** notation says how big a network is: the `/number` = how many bits are fixed.

| CIDR | Addresses | Example |
|---|---|---|
| `/32` | 1 | a single IP (`203.0.113.5/32` = "only my IP") |
| `/24` | 256 | `192.168.1.0/24` (typical home Wi-Fi) |
| `/20` | 4,096 | one default AWS subnet |
| `/16` | 65,536 | AWS default VPC `172.31.0.0/16` |
| `/0` | everything | `0.0.0.0/0` = "anywhere on the internet" |

- **Private ranges** (not reachable from the internet): `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`.
- My EC2 server has **two** addresses:
  - **Private IP** `172.31.x.x`: inside the VPC; it's the only one the server itself sees (`ip a`).
  - **Public / Elastic IP**: AWS's Internet Gateway translates (NATs) it to the private IP.
- **Elastic IP** = a public IP reserved for my account, so it doesn't change when the instance stops or starts.

## AWS networking building blocks
| Piece | What it is |
|---|---|
| **Region** | A geographic location (`ap-southeast-1` = Singapore) |
| **Availability Zone** | A separate data centre inside a region (`ap-southeast-1a`) |
| **VPC** | My private network in AWS |
| **Subnet** | A slice of the VPC inside one AZ; *public* subnet = has a route to the Internet Gateway |
| **Internet Gateway** | The VPC's door to the internet |
| **Route table** | Rules for where traffic goes (`0.0.0.0/0 → igw-...`) |
| **Security Group** | Firewall attached to the instance |

## DNS
DNS turns names into IPs, like a phone book.

```
Browser → "chaos-arena-lenon.duckdns.org?" → resolver (ISP / 8.8.8.8 / 1.1.1.1)
        → asks duckdns.org's nameservers → "A record: 13.x.x.x" → browser connects to 13.x.x.x
```
| Record | Purpose |
|---|---|
| **A** | name → IPv4 address (what DuckDNS sets) |
| **AAAA** | name → IPv6 address |
| **CNAME** | name → another name (alias) |
| **MX** | where email for the domain goes |
| **TXT** | text, e.g. domain verification |
| **TTL** | how long resolvers cache the answer (seconds) |

Testing: `nslookup name` (Windows), `dig +short name` (Linux).

## Ports & protocols
A port is a numbered "door" on an IP. IP + port = a specific service.

| Port | Service | Open on Chaos Arena? |
|---|---|---|
| 22 | SSH | Yes, **my IP only**, rate-limited |
| 80 | HTTP | Yes (redirects to 443) |
| 443 | HTTPS | Yes |
| 3000 | Node.js app (Module 03) | No, Nginx forwards to it internally |
| 3306 / 5432 | MySQL / PostgreSQL | No, never expose databases |

- **TCP**: reliable, ordered (web, SSH). **UDP**: fast, no guarantees (DNS lookups, games, voice).
- `ss -tulpn` shows which ports the server is listening on, and which program owns each one.

## Firewalls: defence in depth
Chaos Arena has **three** layers:

| Layer | Where | Behaviour |
|---|---|---|
| **Security Group** | AWS, before traffic reaches the VM | *Stateful*: replies are allowed automatically. Allow-rules only. |
| **UFW** (iptables/nftables) | Inside Ubuntu | Default deny incoming; allow 22 (limited), 80, 443 |
| **fail2ban** | Inside Ubuntu | Watches SSH logs; bans IPs after 5 failures for 1 hour |

(AWS also has **Network ACLs** at the subnet level. They're stateless and I left them at the default "allow all".)

If one layer is misconfigured, the others still protect the server.

## HTTPS / TLS
- HTTPS = HTTP inside an encrypted TLS tunnel. The certificate proves the server really owns the domain.
- **Let's Encrypt** gives free 90-day certificates; **certbot** gets and auto-renews them (systemd timer).
- To prove I own the domain, Let's Encrypt fetches a file over **port 80** (the HTTP-01 challenge). That's why port 80 must stay open.

## Handy test commands
| Linux (server) | Windows (my PC) | Purpose |
|---|---|---|
| `ip -4 -brief address` | `ipconfig` | My IP addresses |
| `ip route` | `route print` | Routing table / default gateway |
| `dig +short NAME` | `nslookup NAME` | DNS lookup |
| `ss -tulpn` | `netstat -ano` | Listening ports |
| `curl -I URL` | `curl.exe -I URL` | HTTP response headers |
| `nc -zv HOST PORT` | `Test-NetConnection HOST -Port PORT` | Is a port reachable? |
| `traceroute HOST` | `tracert HOST` | Path packets take |
