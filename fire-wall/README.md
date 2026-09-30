# Firewall

A server running three apps, first **wide open** and then protected by an `iptables` host firewall. You attack it before and after, and watch what changes.

## The idea: a server with too many open doors

Imagine a small company server:

- A **website** on port 80, which everyone should reach.
- An **admin panel** on port 9000, which only the office should reach.
- A **database** on port 6379 with no password, which nobody outside should reach.

Out of the box, all three are reachable by anyone. A firewall fixes that without touching the apps.

| In the story            | In the demo                                   |
|-------------------------|-----------------------------------------------|
| The server              | `server` container (has `iptables`)           |
| Website                 | `web` (nginx, port 80)                        |
| Admin panel             | `admin` (whoami, port 9000)                   |
| Database                | `db` (Redis, port 6379, no password)          |
| Someone on the internet | `attacker` container (`172.29.10.30`)         |
| The office              | `office` container (`172.29.10.20`)           |
| The firewall rules      | `demo/firewall/rules.sh`                      |

```
                      ┌──────────── server 172.29.10.10 ────────────┐
attacker .30 ──┐      │  firewall (iptables)                        │
               ├──────┼──►  :80   web    (nginx)                    │
office   .20 ──┘      │     :9000 admin  (whoami)                   │
                      │     :6379 db     (redis)                    │
                      └─────────────────────────────────────────────┘
```

`web`, `admin` and `db` share the `server` container's network stack (`network_mode: "service:server"`). To the outside world they are **one machine with one IP**, just like three apps on one VM, so the server's firewall protects all of them.

## Walkthrough

Requirements: Docker with Docker Compose v2.

### Step 1: Start the demo

```bash
cd fire-wall/demo
docker compose up -d --build
docker compose ps
```

You should see six containers `Up`: `server`, `web`, `admin`, `db`, `attacker` and `office`.

### Step 2: Attack the unprotected server

Go inside the attacker:

```bash
docker compose exec attacker sh
```

Scan the server's ports:

```sh
nmap -Pn -p 80,6379,9000 server
```

**Result:**

```
PORT     STATE SERVICE
80/tcp   open  http
6379/tcp open  redis
9000/tcp open  cslistener
```

Everything is open. Try each door:

```sh
curl -s server | head -4                  # the website: fine, that's public
curl -s server:9000                       # the admin panel: should NOT work from here
redis-cli -h server set hacked yes        # write into the database: OK
redis-cli -h server get hacked            # "yes"
```

The attacker can open the admin panel and write to your database. This is how thousands of real Redis and MongoDB servers have been wiped or held for ransom.

Leave the attacker with `exit`.

### Step 3: Turn the firewall on

```bash
docker compose exec server sh /firewall/rules.sh
```

The script prints the rules it loaded. The important ones:

```
Chain INPUT (policy DROP)                       ← anything not matched below is dropped
1  ACCEPT  all   -- lo                          ← apps on the server talking to each other
2  ACCEPT  all   ctstate RELATED,ESTABLISHED    ← replies to our own connections
3  ACCEPT  icmp                                 ← ping
4  ACCEPT  tcp   dpt:80                         ← website: everyone
5  ACCEPT  tcp   172.29.10.20  dpt:9000         ← admin: office only
```

There's no rule for 6379, so the database is blocked by the `DROP` policy.

### Step 4: Attack again

```bash
docker compose exec attacker sh
```

```sh
nmap -Pn -p 80,6379,9000 server
```

**Result:**

```
PORT     STATE    SERVICE
80/tcp   open     http
6379/tcp filtered redis
9000/tcp filtered cslistener
```

`filtered` means nmap got **no answer at all**. The firewall silently dropped the packets.

```sh
curl -s server | head -4                        # still works
curl -s --max-time 3 server:9000                # hangs, then times out
redis-cli -h server -t 3 ping                   # hangs, then times out (-t needs redis-cli 7.2+)
```

The apps didn't change and are still running. Only the firewall's decision changed.

`exit` the attacker.

### Step 5: The office can reach the admin panel

```bash
docker compose exec office sh
```

```sh
curl -s server:9000                       # works: the office IP is allowed
redis-cli -h server -t 3 ping             # still blocked: the office doesn't need the database
```

Same network, same server, different result, because the rule matches on the **source IP**. `exit` when done.

### Step 6: The apps can still use the database

The database isn't broken. It's only closed to the outside. Apps on the server reach it over `localhost`, which rule 1 (`lo`) allows:

```bash
docker compose exec db redis-cli ping           # PONG
docker compose exec db redis-cli get hacked     # "yes", left over from Step 2
```

This is the typical real-world setup: the database listens locally or on a private network, and only the web port faces the internet.

### Step 7: See which rules are doing the work

```bash
docker compose exec server iptables -L INPUT -v -n --line-numbers
```

The `pkts` and `bytes` columns count how many packets matched each rule. Run the attacker's scan again and watch the counters change. Blocked packets aren't counted by any rule. They fall through to the policy, whose counter is on the `Chain INPUT (policy DROP N packets ...)` line.

### Step 8: Egress, controlling what the server can reach

The firewall also controls **outgoing** traffic. `rules.sh` only allows DNS and HTTPS out:

```bash
docker compose exec server curl -sI https://example.com | head -1                 # HTTP/1.1 200 OK
docker compose exec server curl -sI --max-time 5 http://example.com | head -1     # times out
```

Why bother? If an attacker ever gets code running on this server, they usually try to download tools or send data out. The fewer places the server can reach, the harder that is. Your [forward proxy demo](../forward-proxy/README.md) takes this further by allowing only specific **domains**.

### Step 9: See why "stateful" matters

Rule 2 (`ESTABLISHED,RELATED`) lets **replies** back in. Delete it:

```bash
docker compose exec server iptables -D INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
```

```bash
docker compose exec server curl -sI --max-time 5 https://example.com | head -1   # now times out
docker compose exec attacker curl -s server | head -4                             # still works
```

- **Outgoing HTTPS is broken.** The request goes out, but the reply from example.com arrives on INPUT, and nothing allows it any more.
- **The website still works.** Incoming requests match rule `dpt:80`, and the replies go out through OUTPUT's own `ESTABLISHED` rule.

A stateful firewall remembers the connections that were allowed and lets their replies through automatically. Without that, you'd have to open every port that a reply might come back on.

Put the rules back:

```bash
docker compose exec server sh /firewall/rules.sh
```

### Step 10: DROP vs REJECT

Blocked traffic can be **dropped** (silence) or **rejected** (an immediate "no"). Make the database reject instead:

```bash
docker compose exec server iptables -A INPUT -p tcp --dport 6379 -j REJECT --reject-with tcp-reset
```

```bash
docker compose exec attacker redis-cli -h server ping              # "Connection refused", instantly
docker compose exec attacker nmap -Pn -p 6379 server               # 6379/tcp closed
```

| Action   | Client sees                 | nmap shows | Good for                                     |
|----------|-----------------------------|------------|----------------------------------------------|
| `DROP`   | Nothing; waits for timeout  | `filtered` | The internet: gives scanners nothing, slows them down |
| `REJECT` | Refused immediately         | `closed`   | Internal networks: legitimate clients fail fast instead of hanging |

Reapply `rules.sh` to go back to DROP.

### Step 11: Turn the firewall off (optional)

```bash
docker compose exec server sh /firewall/reset.sh
```

Everything is open again, as in Step 2. Reapply with `rules.sh`.

### Step 12: Clean up

```bash
docker compose down
```

Firewall rules live in the server's memory, so they disappear with the container. A fresh `up` starts wide open again.

### What you just saw

| Step | What it shows                                                          |
|------|------------------------------------------------------------------------|
| 2    | Without a firewall, **every listening port is reachable**              |
| 3–4  | Deny by default, allow only the website                                |
| 5    | Rules can allow by **source IP** (office only)                         |
| 6    | Blocking outside access doesn't break **local** access                 |
| 7    | Counters show **which rule** handled traffic                           |
| 8    | **Egress** filtering limits what a compromised server can do           |
| 9    | **Stateful** tracking lets replies back in                             |
| 10   | **DROP** (silent) vs **REJECT** (refused)                              |

## What's in the demo

```
demo/
├── docker-compose.yml     # server + web/admin/db (sharing its network) + attacker + office
└── firewall/
    ├── rules.sh           # turns the firewall on
    └── reset.sh           # turns it off (allow everything)
```

- `server` is built from Alpine with `iptables` installed. `cap_add: [NET_ADMIN]` allows it to change firewall rules. Without it, `iptables` fails with `Permission denied`.
- `web`, `admin` and `db` use `network_mode: "service:server"`, so they share the server's IP and firewall.
- The `public` network has a fixed subnet (`172.29.10.0/24`) so rules can refer to fixed IPs. If this range clashes with a network you already have, change the subnet and the IPs in both `docker-compose.yml` and `rules.sh`.
- No ports are published to your machine. All traffic comes from the `attacker` and `office` containers.
- `name: firewall-demo` gives this demo its own Compose project, so it doesn't clash with the other `demo` folders.

### iptables in 60 seconds

```
iptables -A INPUT -p tcp --dport 80 -s 1.2.3.4 -j ACCEPT
         │   │     │       │          │          └── action: ACCEPT, DROP, REJECT, LOG
         │   │     │       │          └───────────── source address (optional)
         │   │     │       └──────────────────────── destination port
         │   │     └──────────────────────────────── protocol
         │   └────────────────────────────────────── chain
         └────────────────────────────────────────── -A append, -I insert at top, -D delete
```

| Chain     | Traffic                                          |
|-----------|--------------------------------------------------|
| `INPUT`   | Coming **into** this machine                     |
| `OUTPUT`  | Leaving **from** this machine                    |
| `FORWARD` | Passing **through** (only if the machine routes) |

- Rules are checked **top to bottom, and the first match wins**.
- `-P INPUT DROP` sets the **policy**: what happens when no rule matches.
- Order matters. `-A` adds a rule at the bottom; `-I INPUT 1` puts it first.

## What is a firewall?

A system that decides which network traffic is **allowed** and which is **blocked**, based on rules about source, destination, port and protocol.

| Type                  | Looks at                                   | Examples                                  |
|-----------------------|--------------------------------------------|-------------------------------------------|
| Stateless packet filter | Each packet on its own                   | Router ACLs, AWS Network ACLs             |
| Stateful firewall     | Connections, so replies are allowed automatically | iptables/nftables, AWS Security Groups |
| Application (WAF)     | HTTP content: paths, headers, payloads     | ModSecurity, Cloudflare WAF, AWS WAF      |

| Where it runs        | Examples                                                   |
|----------------------|------------------------------------------------------------|
| On the host          | `iptables`/`nftables`, `ufw`, `firewalld` (this demo)      |
| At the network edge  | pfSense, Palo Alto, Fortinet                               |
| In the cloud         | AWS Security Groups, GCP firewall rules, Azure NSGs        |
| In Kubernetes        | NetworkPolicies (Calico, Cilium)                           |

This demo's `rules.sh` is roughly what a cloud **Security Group** does for you: deny inbound by default, allow listed ports from listed sources, and allow replies automatically.

### Firewall vs proxies

|                  | Firewall                       | Forward proxy                 | Reverse proxy                 |
|------------------|--------------------------------|-------------------------------|-------------------------------|
| Job              | Allow or block traffic         | Send client traffic out       | Receive traffic for servers   |
| Decides based on | IPs, ports, protocols          | Domains, URLs                 | Hosts, paths                  |
| Terminates the connection? | No, it passes packets through | Yes               | Yes                           |

They are usually used together: the firewall only lets 443 in to the reverse proxy, and only lets the servers out through the forward proxy.

## What problems does it solve?

| Problem                                               | How a firewall helps                              |
|-------------------------------------------------------|---------------------------------------------------|
| Apps listen on more ports than you realise            | Only the ports you allow are reachable            |
| A database or admin panel was exposed by mistake      | Deny-by-default hides it even when misconfigured  |
| Bots constantly scan the internet for open ports      | Dropped packets give them nothing to find         |
| A compromised server tries to download tools or leak data | Egress rules limit where it can connect      |
| Admin access should come only from trusted places     | Rules can match on source IP                      |

## Notes and gotchas

### A firewall doesn't stop attacks through allowed ports

Port 80 is open to everyone, so a bug in the website (like SQL injection) comes straight through. That's the job of a **WAF** and of secure code. A firewall only decides *who can knock on which door*.

### Docker and ufw on a real server

On a normal Linux host, Docker writes its own iptables rules for published ports (`-p 8080:80`). These run **before** ufw's rules, so a published container port is reachable **even if ufw blocks it**. Fixes: publish only on localhost (`-p 127.0.0.1:8080:80`), put rules in the `DOCKER-USER` chain, or rely on a cloud firewall in front of the host.

In this demo the rules are inside the server container's own network namespace, so Docker's host rules don't interfere.

### Don't lock yourself out

On a remote server, running `iptables -P INPUT DROP` before allowing SSH (port 22) cuts off your own session. Always allow your access first, and use a tool with a safety net such as `ufw` or `iptables-apply`, which rolls back if you don't confirm.

### Rules don't survive a reboot

`iptables` rules live in the kernel's memory. On a real server, save them with `iptables-save` / `iptables-restore` (the `iptables-persistent` package), or use `ufw` / `firewalld`, which save rules for you.

### iptables, nftables and ufw

- **nftables** (`nft`) is the modern replacement for iptables. On current distributions, the `iptables` command is often a front end that writes nftables rules.
- **ufw** (Ubuntu) and **firewalld** (RHEL, Fedora) are friendlier tools that generate these rules for you. The same policy as Step 3 in ufw:

```bash
ufw default deny incoming
ufw default deny outgoing
ufw allow 80/tcp
ufw allow from 172.29.10.20 to any port 9000 proto tcp
ufw allow out 53
ufw allow out 443/tcp
ufw enable
```

### IPv6 has its own rules

`iptables` only covers IPv4. IPv6 needs `ip6tables` (or an nftables `inet` table, which covers both). A server with a locked-down IPv4 firewall and no IPv6 rules can still be wide open over IPv6. Docker networks in this demo are IPv4 only.

## Handy commands

```bash
docker compose exec server iptables -L -v -n --line-numbers   # rules with counters
docker compose exec server iptables -S                        # rules as commands
docker compose exec server iptables -Z                        # reset counters
docker compose exec server iptables -D INPUT 4                # delete rule 4 of INPUT
docker compose exec server sh /firewall/rules.sh              # firewall on
docker compose exec server sh /firewall/reset.sh              # firewall off
docker compose exec attacker nmap -Pn -p 1-10000 server       # scan a wider range
```
