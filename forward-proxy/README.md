# Forward Proxy

A Squid forward proxy that is the **only way out** of a private network, and only to allow-listed domains.

## The idea: an office with no internet

Imagine a company office:

- **Employee computers** aren't allowed on the internet at all.
- There's **one gatekeeper** who does have internet access.
- The gatekeeper holds a **list of approved websites**. If you ask for an approved site, the gatekeeper fetches it for you. Otherwise the request is refused.
- The gatekeeper also **writes down every request** in a log.

The demo builds exactly this with two containers:

| In the office story       | In the demo                         |
|---------------------------|-------------------------------------|
| Employee computer         | `client` container                  |
| Gatekeeper                | `proxy` container (Squid)           |
| List of approved websites | `demo/squid/allowed-domains.txt`    |
| The gatekeeper's notebook | `/var/log/squid/access.log`         |

```
┌───────── private network (no internet) ─────────┐
│                                                   │
│   client  ───── "please fetch X" ────►  proxy ────┼───► internet
│                                                   │
└───────────────────────────────────────────────────┘
```

The `client` only has the private network, so its **only** way out is to ask the proxy.

## Walkthrough

Requirements: Docker with Docker Compose v2.

You'll use **two terminals**: one for the client, and one to watch the proxy's log.

### Step 1: Start the demo

```bash
cd forward-proxy/demo
docker compose up -d
docker compose ps
```

You should see three containers, `proxy`, `client` and `client-auto`, all `Up`. (`client-auto` is only used in Step 8b.)

### Step 2: Terminal 2, watch the proxy's log

```bash
cd forward-proxy/demo
docker compose exec proxy tail -f /var/log/squid/access.log
```

Leave this running. It prints one line each time the proxy handles a request. It stays empty until you send requests in Step 3.

### Step 3: Terminal 1, go inside the client

```bash
docker compose exec client sh
```

Your prompt changes, because you're now **inside the private computer**. Every command from here on runs as the client. (Type `exit` to leave.)

### Step 4: Try the internet directly

```sh
curl https://example.com
```

**Result:** `Could not resolve host: example.com`

**Why:** the client is on a network with no route to the internet, so it can't even look up the address.
**Terminal 2:** nothing. The proxy wasn't involved.

### Step 5: Ask the proxy to fetch it

```sh
curl -x http://proxy:3128 https://example.com
```

`-x http://proxy:3128` tells curl to send the request to the proxy (on port 3128) instead of going directly.

**Result:** the HTML of example.com is printed.
**Terminal 2:** a new line:

```
... TCP_TUNNEL/200 ... CONNECT example.com:443 ...
```

The proxy fetched it for you (`200` = success).

### Step 6: Ask for a site that isn't on the list

```sh
curl -x http://proxy:3128 https://google.com
```

**Result:** `CONNECT tunnel failed, response 403`
**Terminal 2:** `TCP_DENIED/403 ... google.com:443`

The proxy refused, because `google.com` isn't in `allowed-domains.txt`.

### Step 7: Add google.com to the allowed list

Open a **third terminal** (or leave the client with `exit`). Then:

```bash
cd forward-proxy/demo
echo ".google.com" >> squid/allowed-domains.txt
docker compose exec proxy squid -k reconfigure     # tell Squid to re-read its config
```

Go back into the client and run the same request again:

```sh
curl -x http://proxy:3128 https://google.com
```

**Result:** it works now. You changed the rules and the proxy enforces them straight away, which is how a company controls outgoing traffic.

(To undo it, delete the `.google.com` line from `squid/allowed-domains.txt` and run the `reconfigure` command again.)

### Step 8: Stop typing `-x` every time

Real tools don't take `-x`. They read an **environment variable** instead:

```sh
export HTTPS_PROXY=http://proxy:3128
curl https://example.com        # no -x, but it still goes through the proxy
```

This is how servers are configured in real companies: set the variable once, and curl, pip, apt, git and others all use the proxy.

### Step 8b: Configure the proxy ahead of time

Typing `export` in every new shell gets tedious, and it's gone as soon as you `exit`. Instead, you can set the variables **before** the container starts. `docker-compose.yml` has a second client, `client-auto`, that does exactly this:

```yaml
  client-auto:
    image: curlimages/curl
    entrypoint: ["sleep", "infinity"]
    environment:                        # set for every process in the container
      HTTP_PROXY: http://proxy:3128
      HTTPS_PROXY: http://proxy:3128
      NO_PROXY: localhost,127.0.0.1     # never send these through the proxy
    networks:
      - internal
```

Leave the current client (`exit`) and go into `client-auto`:

```bash
docker compose exec client-auto sh
```

```sh
env | grep -i proxy             # the variables are already set
curl https://example.com        # works: no export, no -x
curl https://google.com         # blocked (403) unless you added it in Step 7
```

**Terminal 2:** the requests appear in the log, just like in Step 5.

`client-auto` is still cut off from the internet. To prove it, tell curl to ignore the proxy:

```sh
curl --noproxy '*' https://example.com    # Could not resolve host, same as Step 4
```

The environment only makes the client **use** the proxy automatically. It's the network that makes the proxy the **only** way out.

The original `client` has no proxy variables, which is why Step 4 still shows the direct request failing. If you add an `environment:` block to your own service, run `docker compose up -d` again: environment changes need the container to be recreated, and a restart isn't enough.

On a real server (without Docker), the equivalent is putting the variables in `/etc/environment` (all users) or `~/.bashrc` (just you). Some tools have their own proxy setting too, for example `/etc/apt/apt.conf.d/`, `git config http.proxy` and `pip config set global.proxy`.

### Step 9: See the proxy's cache

```sh
curl -x http://proxy:3128 http://example.com -o /dev/null
curl -x http://proxy:3128 http://example.com -o /dev/null
```

(Note: `http`, not `https`.)
**Terminal 2:**

```
... TCP_MISS/200    GET http://example.com/     ← 1st time: downloaded from the internet
... TCP_MEM_HIT/200 GET http://example.com/     ← 2nd time: served from the proxy's memory
```

The second request never left the office. With 100 machines downloading the same file, it's only downloaded once. Caching only works with `http` because HTTPS traffic is encrypted, and the proxy can't read or store it.

### Step 10: Clean up

```sh
exit                      # leave the client
```

```bash
docker compose down
```

### What you just saw

| Step       | What it shows                                                    |
|------------|------------------------------------------------------------------|
| 4          | The private machine **can't** reach the internet on its own      |
| 5          | The proxy is the **only way out**                                 |
| 6          | The proxy **blocks** anything not approved                        |
| 7          | You **control** outgoing traffic by editing one file              |
| 8          | Real tools use the proxy through **environment variables**        |
| 8b         | Set those variables **ahead of time** so nothing is typed by hand |
| 9          | The proxy **caches** repeated downloads                           |
| Terminal 2 | Every request is **logged**, so you can audit who went where      |


### Reading the access log

```
... 172.28.0.2 TCP_TUNNEL/200   CONNECT example.com:443      HIER_DIRECT/104.20.23.154
... 172.28.0.2 TCP_DENIED/403   CONNECT google.com:443       HIER_NONE/-
... 172.28.0.2 TCP_MISS/200     GET http://example.com/      HIER_DIRECT/104.20.23.154
... 172.28.0.2 TCP_MEM_HIT/200  GET http://example.com/      HIER_NONE/-
```

| Code          | Meaning                                                         |
|---------------|-----------------------------------------------------------------|
| `TCP_TUNNEL`  | HTTPS: the proxy opened an encrypted tunnel (it only sees the domain) |
| `TCP_DENIED`  | Blocked by an `http_access` rule                                |
| `TCP_MISS`    | Not in the cache: fetched from the internet                     |
| `TCP_MEM_HIT` | Served from the in-memory cache, without contacting the internet |
| `HIER_DIRECT` | The proxy contacted the destination itself                      |
| `HIER_NONE`   | No outbound connection was made (denied or cached)              |

## What's in the demo

```
demo/
├── docker-compose.yml            # proxy (Squid) + client + client-auto (curl)
└── squid/
    ├── squid.conf                # access rules, cache, logging
    └── allowed-domains.txt       # the egress allow-list
```

```
 internal network (internal: true)          external network
┌──────────────────────────────────┐
│  client ──────────► proxy ───────┼──────────► internet
│    │                             │
│    └──✗──► internet (no route)   │
└──────────────────────────────────┘
```

- `client` is **only** on the `internal` network. `internal: true` tells Docker not to give that network any route outside, so the client can't reach the internet or resolve outside hostnames.
- `client-auto` is the same as `client`, plus `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` in its `environment:`, so tools inside it use the proxy automatically (Step 8b).
- `proxy` is on **both** networks, which makes it the single exit.
- No ports are published. Only containers on `internal` can use the proxy.
- `name: forward-proxy-demo` in `docker-compose.yml` gives the demo its own Compose project. Without it, the project name comes from the folder (`demo`), which clashes with `reverse-proxy/demo`, and Compose would replace that demo's containers.

### squid.conf

```
acl localnet src 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16   # who: private networks
acl allowed_domains dstdomain "/etc/squid/allowed-domains.txt"  # where: the allow-list

http_access deny !Safe_ports               # only ports 80/443
http_access deny CONNECT !SSL_ports        # HTTPS tunnels only to 443
http_access allow localnet allowed_domains # private clients -> allowed domains
http_access deny all                       # everything else
```

- `acl` defines a named condition, and `http_access` allows or denies requests that match it.
- Rules are checked **from top to bottom, and the first match wins**. Always end with `deny all`.
- In `allowed-domains.txt`, `.github.com` (with the leading dot) matches `github.com` **and** all its subdomains.

To allow a new domain, add it to `allowed-domains.txt`, then reload:

```bash
docker compose exec proxy squid -k reconfigure
```

## What is a forward proxy?

A server that sits **in front of clients** and sends their requests out on their behalf. The destination sees the proxy, not the client.

```
Forward proxy:  [your clients] ──► proxy ──► the internet     (outbound)
Reverse proxy:  the internet ──► proxy ──► [your servers]     (inbound)
```

- A **reverse proxy** solves the server owner's problems: serving incoming traffic well.
- A **forward proxy** solves the client side's problems: controlling, securing and enabling outgoing traffic.

## What problems does it solve?

| Problem                                          | How a forward proxy helps                                           |
|--------------------------------------------------|---------------------------------------------------------------------|
| Private servers must not reach the internet directly | One controlled exit. The firewall only needs to allow the proxy out |
| A compromised server could send data out         | **Egress allow-list**: only approved domains are reachable          |
| "Which machine contacted this domain?"           | **Audit log** of every outbound request                             |
| A partner API only accepts allow-listed IPs      | All traffic leaves from **one fixed IP**                            |
| Many machines download the same packages         | **Shared cache**: download once, serve locally                      |
| Hiding the client                                | The destination only sees the proxy's IP                            |

|                                | Forward proxy                           | Reverse proxy                 |
|--------------------------------|-----------------------------------------|-------------------------------|
| Traffic direction              | Outbound (clients → internet)           | Inbound (internet → servers)  |
| Who sets it up                 | Client-side network or IT team          | Server owner                  |
| Does the client know about it? | **Yes**, it's configured explicitly     | **No**                        |
| What it hides                  | Who the client is                       | What the backend looks like   |
| Typical tools                  | Squid, Tinyproxy, Zscaler, VPNs, Tor    | Nginx, HAProxy, Traefik, Envoy|

## Notes and gotchas

### HTTPS: the proxy only sees the domain

For `https://` URLs the client sends `CONNECT example.com:443`, and the proxy then passes **encrypted bytes** through. It can allow or block by domain, but it can't see paths, headers or bodies, and it **can't cache** HTTPS responses. That's why caching in this demo only works with `http://`.

Seeing inside HTTPS requires **TLS interception** (Squid's `ssl_bump`). The organisation installs its own certificate authority on every client, and the proxy decrypts and re-encrypts the traffic. Many corporate proxies do this.

### Proxy environment variables

Most CLI tools (curl, apt, pip, npm, git) read these variables:

```bash
export HTTP_PROXY=http://proxy:3128
export HTTPS_PROXY=http://proxy:3128    # the proxy URL is usually http://, even for HTTPS traffic
export NO_PROXY=localhost,127.0.0.1,.internal.example.com   # skip the proxy for these
```

- Some tools only read the lowercase names (`http_proxy`), so it's common to set both.
- Keep internal addresses in `NO_PROXY`, otherwise requests to internal services also go through the proxy and get blocked.
- The **Docker daemon** doesn't use your shell's variables. `docker pull` needs the proxy configured separately (for example in `/etc/docker/daemon.json` under `"proxies"`, or in a systemd drop-in).

### Squid 6 no longer sends an `X-Cache` header

Older guides check cache hits with the `X-Cache: HIT` response header. Squid 6 dropped it, so use the access log instead (`TCP_MISS`, then `TCP_HIT` / `TCP_MEM_HIT`).

## Handy commands

```bash
docker compose exec proxy squid -k parse          # validate squid.conf
docker compose exec proxy squid -k reconfigure    # reload config without restarting
docker compose exec proxy tail -f /var/log/squid/access.log
docker compose logs proxy                         # startup and error messages
```
