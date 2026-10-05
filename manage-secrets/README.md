# Secret Management

The bakery app needs an API key and a database password. Instead of writing them in code, it asks **HashiCorp Vault** at startup. Vault checks what the app is allowed to read, hands out a database login that **expires after 1 minute**, and logs every request.

## What is secret management?

Keeping **passwords, API keys, tokens and private keys** out of code, and controlling who gets them.

| Rule                        | Meaning                                                       |
|-----------------------------|---------------------------------------------------------------|
| Never in code or git        | Code names the secret it needs; the value lives somewhere else |
| Least privilege             | Each app/person can read only what it needs                   |
| Short-lived where possible  | A leaked secret that expires in minutes is nearly harmless     |
| Rotate                      | Change secrets regularly, and immediately after a leak        |
| Audit                       | Know who read what, and when                                  |

## The idea: the app knows no passwords

```
                 1. login (AppRole)              ┌──────────── Vault ─────────────┐
 app ──────────────────────────────────────────► │ policy: bakery-app             │
     ◄──────────── token ─────────────────────── │                                │
     ── 2. read secret/bakery/config ──────────► │ KV store: api_key=sk_live_...  │
     ── 3. read database/creds/bakery ─────────► │ DB engine ──CREATE ROLE──► db  │
     ◄──────────── user v-approle-bakery-..., ── │ (expires in 1m, then DROP)     │
     │             password, expires in 60s      │ audit log: every request       │
     │                                           └────────────────────────────────┘
     └── 4. psql with the temporary login ──────────────────────────────► db (postgres)
```

| In the story                  | In the demo                                                    |
|-------------------------------|----------------------------------------------------------------|
| The vault                     | `vault` container, dev mode, UI on `localhost:8200`            |
| The bakery database           | `db` (Postgres) with an `orders` table                         |
| The bakery app                | `app` container: a shell script calling Vault's HTTP API       |
| The admin who sets things up  | `setup` container, runs `vault/setup.sh` once with the root token |

## Walkthrough

Requirements: Docker with Docker Compose v2.

### Step 0: Why bother? A secret in git never goes away

Try this in a throwaway folder (not this repo):

```bash
cd "$(mktemp -d)" && git init -q
echo 'DB_PASSWORD=SuperSecret123' > config.env
git add . && git commit -qm "add config"
git rm -q config.env && git commit -qm "remove password"   # "fixed"?

ls                    # file is gone...
git log -p | grep DB_PASSWORD     # ...but the password is still in history
```

Anyone who clones the repo gets the history. Bots scan public GitHub for keys within minutes. The only real fix is to **change the password**. Vault's goal is that there's nothing to leak in the first place.

### Step 1: Start Vault, the database, and run the setup

```bash
cd manage-secrets/demo
docker compose up -d
docker compose logs setup        # ends with "Setup done"
```

Open **http://localhost:8200**, choose *Token*, enter `root`. Browse *Secrets → secret → bakery → config*.

The `setup` container did what an admin would (see `vault/setup.sh`):

| What                       | Command in `setup.sh`                        |
|----------------------------|----------------------------------------------|
| Turn on the audit log      | `vault audit enable file ...`                |
| Store static secrets       | `vault kv put secret/bakery/config ...`      |
| Write the app's policy     | `vault policy write bakery-app ...`          |
| Connect Vault to Postgres  | `vault write database/config/postgres ...`   |
| Define temporary DB logins | `vault write database/roles/bakery ...`      |
| Give the app a login       | `vault auth enable approle` + role-id/secret-id |

### Step 2: Static secrets (KV): store, read, version

All `vault` commands below run inside the `vault` container as admin (root token):

```bash
docker compose exec vault vault kv get secret/bakery/config
docker compose exec vault vault kv get -field=api_key secret/bakery/config
```

Rotate the API key. Vault keeps the old version:

```bash
docker compose exec vault vault kv put secret/bakery/config api_key=sk_live_NEW_456 payment_provider=stripe
docker compose exec vault vault kv get -version=1 secret/bakery/config   # old value still there
docker compose exec vault vault kv metadata get secret/bakery/config     # version history
```

Made a mistake? `vault kv rollback -version=1 secret/bakery/config`.

### Step 3: Run the app

```bash
docker compose run --rm --build app
```

```
1. Log in to Vault with AppRole
   token: hvs.CAESIJ8x...  (policy: bakery-app)

2. Read a static secret: secret/bakery/config
   api_key: sk_live_****  (version 2)

3. Ask for a database login, created just for this app run
   user:    v-approle-bakery-Xq3k9Lm2...-1728123456
   expires: in 60s

4. Use it
          current_user           | orders
 --------------------------------+--------
  v-approle-bakery-Xq3k9Lm2...   |      3

5. Try to read a secret outside my policy: secret/admin/backup-key
   HTTP 403  (403 = permission denied, as expected)
```

Look at `app/app.sh`: there's **no password anywhere**. The app only has its AppRole login (`role_id` + `secret_id`), and Vault decides the rest.

### Step 4: Policies: least privilege

The app's policy (`vault/bakery-app.hcl`) allows exactly two paths. Everything else is denied, which is why step 5 got `403`.

Try it as the app would, with a token that only has `bakery-app`:

```bash
docker compose exec vault sh -c '
  T=$(vault token create -policy=bakery-app -field=token)
  VAULT_TOKEN=$T vault kv get secret/bakery/config       # ✅ allowed
  VAULT_TOKEN=$T vault kv get secret/admin/backup-key    # ❌ permission denied
  VAULT_TOKEN=$T vault kv put secret/bakery/config x=1   # ❌ read-only
'
```

### Step 5: Dynamic secrets: a new DB user every time, gone after 1 minute

Run the app twice and look at the username. It's different each time:

```bash
docker compose run --rm app | grep user:
docker compose run --rm app | grep user:
```

See them in Postgres:

```bash
docker compose exec db psql -U postgres -d bakery -c '\du'
#  v-approle-bakery-Xq3k...  | Password valid until 2026-10-05 10:31:00
#  v-approle-bakery-Pm8w...  | ...
```

Wait about 1 minute and run `\du` again. **They're gone.** Vault dropped them when their lease expired.

| Static password (normal)                  | Dynamic credentials (Vault)                    |
|-------------------------------------------|------------------------------------------------|
| One password shared by every app instance | One user per app instance / per run            |
| Valid forever, until someone changes it   | Expires automatically (here: 1 minute)         |
| Leak → change it everywhere, redeploy     | Leak → useless soon; or revoke that one lease  |
| Logs show "the app" did it                | Logs show *which* instance did it              |

### Step 6: Revoke: kill access right now

Suspect a leak? Don't wait for the TTL:

```bash
docker compose run --rm app > /dev/null                    # create a login
docker compose exec vault vault list sys/leases/lookup/database/creds/bakery
docker compose exec vault vault lease revoke -prefix database/creds/bakery
docker compose exec db psql -U postgres -d bakery -c '\du'  # dropped immediately
```

### Step 7: Audit log: who read what?

```bash
docker compose exec vault sh -c 'grep -o "\"path\":\"[^\"]*\"" /vault/logs/audit.log | sort | uniq -c'
```

```
      4 "path":"auth/approle/login"
      4 "path":"database/creds/bakery"
      2 "path":"secret/data/admin/backup-key"
      ...
```

Look at one full entry with `tail -n 1 /vault/logs/audit.log`. Secret values in the log are **hashed** (`hmac-sha256:...`), so the audit log itself doesn't leak them.

### Step 8: Rotate the root password: now even you don't know it

The Postgres admin password `postgres-admin-pw` is written in `docker-compose.yml`, which is a leak waiting to happen. Let Vault replace it with a random one only Vault knows.

Before (the password works over the network):

```bash
docker compose run --rm --entrypoint sh app -c \
  "PGPASSWORD=postgres-admin-pw psql -h db -U postgres -d bakery -c 'select 1'"   # ✅
```

Rotate:

```bash
docker compose exec vault vault write -f database/rotate-root/postgres
```

After:

```bash
docker compose run --rm --entrypoint sh app -c \
  "PGPASSWORD=postgres-admin-pw psql -h db -U postgres -d bakery -c 'select 1'"   # ❌ password authentication failed
docker compose run --rm app        # ✅ still works: Vault uses the new password
```

The password in `docker-compose.yml` is now worthless. Do this step **last**: `setup.sh` uses the old password, so re-running setup now fails until you reset.

Clean up:

```bash
docker compose down -v
```

## What's in the demo

```
demo/
├── docker-compose.yml       # vault, db, setup (one-shot), app (on demand)
├── vault/
│   ├── setup.sh             # admin setup: audit, KV, policy, DB engine, AppRole
│   ├── bakery-app.hcl       # the app's policy (what it may read)
│   └── bakery-role.sql      # SQL Vault runs to create each temporary DB user
├── db/init.sql              # orders table + sample rows
└── app/
    ├── Dockerfile           # alpine + curl + jq + psql
    └── app.sh               # the app: login → read secret → get DB login → query
```

## Key concepts

| Term              | Meaning                                                         | In the demo                      |
|-------------------|-----------------------------------------------------------------|----------------------------------|
| Secrets engine    | A plugin that stores or generates secrets, mounted at a path    | `secret/` (KV), `database/`      |
| KV v2             | Key/value store with version history                            | `secret/bakery/config`           |
| Dynamic secret    | Created on request, unique, expires automatically               | `database/creds/bakery`          |
| Lease / TTL       | How long a dynamic secret lives                                 | `default_ttl=1m`, `max_ttl=5m`   |
| Auth method       | How a person or machine proves who it is                        | Token (you), AppRole (the app)   |
| Token             | What you get after logging in; used on every request            | `X-Vault-Token` header in `app.sh` |
| Policy            | Which paths a token may use, and how                            | `bakery-app.hcl`                 |
| Audit device      | Log of every request, with secret values hashed                 | `/vault/logs/audit.log`          |
| Seal / unseal     | Vault's storage is encrypted; it must be unsealed to start      | Skipped in dev mode              |

## Notes and gotchas

### Dev mode is for learning only

`server -dev` keeps everything **in memory**, starts **unsealed**, uses HTTP, and has a fixed root token. If you restart the `vault` container, all secrets and config are gone. Re-run setup with `docker compose down -v && docker compose up -d`.

A real Vault uses persistent storage (Raft), TLS, real unsealing (often auto-unseal with a cloud KMS), and **no** day-to-day use of the root token.

### "Secret zero": how does the app get its first secret?

The app still needs *something* to log in: the AppRole `secret_id`. Here, `setup` writes it into a shared volume. In real life it's delivered by the platform. Examples:

- **Kubernetes**: the pod's service account proves who it is (`kubernetes` auth method)
- **AWS / Azure / GCP**: the VM's cloud identity (`aws`, `azure`, `gcp` auth methods)
- **CI/CD**: GitHub Actions' OIDC token (`jwt` auth method), so no stored secret at all

The idea is to replace a long-lived password with an **identity the platform already vouches for**.

### Real apps use an SDK or Vault Agent

`app.sh` calls the HTTP API with `curl` so you can see every request. Real apps use a Vault library for their language, or run **Vault Agent** next to them. The agent logs in, writes secrets to a file, and renews or refreshes them, so the app just reads a file.

### Dynamic credentials expire *while* the app runs

With `default_ttl=1m`, a long-running app must **renew** its lease or fetch new credentials before expiry. Vault Agent and SDKs handle this. Choose TTLs to match how long your app needs them.

### `hashicorp/vault` license

Vault uses the Business Source License, which is free for learning and internal use. **OpenBao** is an open-source fork with almost identical commands, if that matters to you.

## How it connects to the other demos

| Demo        | Secret problem                                  | With Vault                                        |
|-------------|-------------------------------------------------|---------------------------------------------------|
| CI/CD       | Deploy needs registry/server credentials        | Pipeline logs in to Vault with GitHub OIDC        |
| Terraform   | Provider passwords; secrets in `tfstate`        | `vault` provider reads them at plan/apply time    |
| Ansible     | Passwords in playbooks / `group_vars`           | `community.hashi_vault` lookup, or Ansible Vault (encrypted files) |
| Firewall    | Redis with no password                          | Dynamic Redis credentials (`redis` DB plugin)     |

## Handy commands

```bash
# Run as admin inside the vault container: docker compose exec vault <command>
vault status                                  # sealed? version? storage?
vault secrets list                            # mounted engines
vault auth list                               # enabled login methods
vault policy read bakery-app                  # show a policy
vault kv get secret/bakery/config             # read
vault kv put secret/bakery/config k=v         # write (new version)
vault read database/creds/bakery              # get a temporary DB login yourself
vault lease revoke -prefix database/creds/bakery   # revoke all of them
vault token lookup                            # who am I, which policies?
```
