# Reverse Proxy

An nginx reverse proxy that load-balances between two backend apps and also routes by path.

## Run the demo

Requirements: Docker with Docker Compose v2.

```bash
cd reverse-proxy/demo
docker compose up -d
```

Try it:

```bash
# Load-balanced: requests are spread between app1 and app2
for i in $(seq 10); do curl -s localhost:8080 | grep Hostname; done

# Path-based routing
curl -s localhost:8080/one/ | grep Hostname   # always app1
curl -s localhost:8080/two/ | grep Hostname   # always app2

# See which container ID belongs to which app
docker ps --format '{{.ID}} {{.Names}}'

# Proxy access logs
docker compose logs -f proxy
```

Clean up:

```bash
docker compose down
```

## What's in the demo

```
demo/
├── docker-compose.yml     # proxy (nginx) + app1 + app2
└── nginx/default.conf     # upstream group + routing rules
```

```
                        ┌──► app1 (traefik/whoami)
curl :8080 ──► nginx ───┤
                        └──► app2 (traefik/whoami)
```

- Only `proxy` publishes a port (`8080:80`). The apps can only be reached **through** the proxy.
- `traefik/whoami` echoes request details, including its `Hostname` (the container ID), so you can see which backend answered.
- nginx reaches the apps by service name (`app1`, `app2`) through Docker's internal DNS.

| Path     | Goes to                            |
|----------|------------------------------------|
| `/`      | `upstream apps` (app1 + app2)      |
| `/one/`  | app1 only                          |
| `/two/`  | app2 only                          |

## What is a reverse proxy?

A server that sits **in front of backend servers** and receives requests on their behalf. Clients only talk to the proxy and never see the backends.

```
Users ──► Reverse Proxy ──► app-server-1
                        ──► app-server-2
```

Forward proxy vs reverse proxy:

|                   | Forward proxy                  | Reverse proxy                |
|-------------------|--------------------------------|------------------------------|
| Acts on behalf of | the client                     | the server                   |
| Hides             | who the client is              | what the backend looks like  |
| Set up by         | the client or its network admin| the server owner             |

## Why use one?

| Problem                                  | What the proxy does                                        |
|------------------------------------------|------------------------------------------------------------|
| One server can't handle the traffic      | **Load balancing** across several backends                 |
| A backend crashes                        | **Failover**: route around the failed backend              |
| Deploys cause downtime                   | **Zero-downtime deploys** (drain a backend, then swap)     |
| Every app manages its own HTTPS          | **TLS termination** in one place                           |
| Many services behind one domain          | **Routing** by path or host (`/api`, `shop.example.com`)   |
| Backends exposed to the internet         | **Security**: hide internals, rate limiting, WAF           |
| Repeated work and slow responses         | **Caching and compression**                                |
| No central view of traffic               | **Observability**: access logs and metrics in one place    |

Common tools: Nginx, HAProxy, Traefik, Envoy, Caddy, cloud load balancers (AWS ALB), and Kubernetes Ingress controllers.

## Notes and gotchas

### Load balancing is on by default

An `upstream` block with more than one `server` **is** a load balancer. With no method specified, nginx uses round robin and these defaults:

```nginx
upstream apps {
    server app1:80 weight=1 max_fails=1 fail_timeout=10s;
    server app2:80 weight=1 max_fails=1 fail_timeout=10s;
}
```

| Setting                      | Default         | Meaning                                                   |
|------------------------------|-----------------|-----------------------------------------------------------|
| Method                       | round robin     | Take turns across servers                                 |
| `weight`                     | 1               | Equal share for each server                               |
| `max_fails` / `fail_timeout` | 1 / 10s         | After 1 failure, skip the server for 10s                  |
| `proxy_next_upstream`        | `error timeout` | If a backend can't be reached, retry on the next one      |

Other methods: `least_conn`, `ip_hash` (sticky by client IP), `hash $request_uri consistent`, `random two least_conn`.

### "Why does it always hit app1?" (per-worker round robin)

Right after startup, `curl localhost:8080` can return app1 many times in a row. The config isn't broken:

- The `nginx:alpine` image sets `worker_processes auto`, so there is one worker per CPU core. nginx's own built-in default is `1`.
- Each worker is a separate process with **its own round-robin counter**, and every counter starts at app1.
- Each `curl` opens a new connection, and the kernel hands it to a worker, often one that hasn't served a request yet, so it picks app1.
- After enough requests the counters drift apart and traffic evens out (roughly 50/50).
- A restart or `nginx -s reload` starts fresh workers and resets every counter.

Ways to see it or fix it:

```bash
# One keep-alive connection stays on one worker, so it alternates exactly
curl -s $(printf 'localhost:8080 %.0s' $(seq 10)) | grep Hostname
```

```yaml
# docker-compose.yml, proxy service: use a single worker (demo only)
command: ["nginx", "-g", "daemon off; worker_processes 1;"]
```

```nginx
# Share balancing state across workers
upstream apps {
    zone apps 64k;
    server app1:80;
    server app2:80;
}
```

Under real traffic this doesn't matter much, because every worker handles plenty of requests.

### A backend goes away

With `docker compose stop app2`, requests still succeed because nginx retries them on app1. However:

- nginx resolves `app2` **once, at startup**, and keeps using the old IP.
- Requests that try app2 first can be **slow** before they're retried on app1.
- Failure state is per worker (unless you add `zone`), so each worker discovers the failure on its own.
- If the proxy **restarts** while app2 is missing, nginx refuses to start: `host not found in upstream "app2:80"`.
- A recreated app2 may get a **new IP**. Run `docker compose exec proxy nginx -s reload` so nginx picks it up.

To take a backend out cleanly, mark it `down` and reload:

```nginx
upstream apps {
    server app1:80;
    server app2:80 down;
}
```

```bash
docker compose exec proxy nginx -s reload
```

## Handy commands

```bash
docker compose exec proxy nginx -t          # test the config
docker compose exec proxy nginx -T          # print the full config nginx loaded
docker compose exec proxy nginx -s reload   # apply config changes without downtime
docker compose exec proxy getent hosts app1 app2   # check Docker DNS
```
