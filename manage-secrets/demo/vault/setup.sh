#!/bin/sh
# Configures Vault for the demo. Runs as root token (admin), once.
set -eu

echo "== Audit log: record every request"
vault audit list 2>/dev/null | grep -q '^file/' \
  || vault audit enable file file_path=/vault/logs/audit.log

echo "== Static secrets (KV v2, mounted at secret/ in dev mode)"
vault kv put secret/bakery/config api_key=sk_live_bakery_123 payment_provider=stripe
vault kv put secret/admin/backup-key value=only-admins-should-see-this

echo "== Policy: what the bakery app may read"
vault policy write bakery-app /setup/bakery-app.hcl

echo "== Dynamic DB credentials: Vault creates a Postgres user on request"
vault secrets list | grep -q '^database/' || vault secrets enable database
vault write database/config/postgres \
  plugin_name=postgresql-database-plugin \
  connection_url='postgresql://{{username}}:{{password}}@db:5432/bakery?sslmode=disable' \
  allowed_roles=bakery \
  username=postgres \
  password=postgres-admin-pw
vault write database/roles/bakery \
  db_name=postgres \
  creation_statements=@/setup/bakery-role.sql \
  default_ttl=1m \
  max_ttl=5m

echo "== AppRole: how the app logs in (like a username + password for machines)"
vault auth list | grep -q '^approle/' || vault auth enable approle
vault write auth/approle/role/bakery token_policies=bakery-app token_ttl=10m
vault read -field=role_id auth/approle/role/bakery/role-id > /app-creds/role_id
vault write -f -field=secret_id auth/approle/role/bakery/secret-id > /app-creds/secret_id

echo "== Setup done. UI: http://localhost:8200 (token: root)"
