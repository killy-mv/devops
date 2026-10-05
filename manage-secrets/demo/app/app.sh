#!/bin/sh
# The bakery app. It has no passwords in its code or config,
# only an AppRole login, and gets everything else from Vault's HTTP API.
set -eu

ROLE_ID=$(cat /app-creds/role_id)
SECRET_ID=$(cat /app-creds/secret_id)

echo "1. Log in to Vault with AppRole"
TOKEN=$(curl -sf -X POST "$VAULT_ADDR/v1/auth/approle/login" \
  -d "{\"role_id\":\"$ROLE_ID\",\"secret_id\":\"$SECRET_ID\"}" | jq -r .auth.client_token)
echo "   token: $(echo "$TOKEN" | cut -c1-12)...  (policy: bakery-app)"

vault_get() {
  curl -sf -H "X-Vault-Token: $TOKEN" "$VAULT_ADDR/v1/$1"
}

echo
echo "2. Read a static secret: secret/bakery/config"
CONFIG=$(vault_get secret/data/bakery/config)
API_KEY=$(echo "$CONFIG" | jq -r .data.data.api_key)
echo "   api_key: $(echo "$API_KEY" | cut -c1-8)****  (version $(echo "$CONFIG" | jq -r .data.metadata.version))"

echo
echo "3. Ask for a database login, created just for this app run"
CREDS=$(vault_get database/creds/bakery)
DB_USER=$(echo "$CREDS" | jq -r .data.username)
DB_PASS=$(echo "$CREDS" | jq -r .data.password)
echo "   user:    $DB_USER"
echo "   expires: in $(echo "$CREDS" | jq -r .lease_duration)s"

echo
echo "4. Use it"
PGPASSWORD=$DB_PASS psql -h db -U "$DB_USER" -d bakery \
  -c "SELECT current_user, (SELECT count(*) FROM orders) AS orders;"

echo "5. Try to read a secret outside my policy: secret/admin/backup-key"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -H "X-Vault-Token: $TOKEN" \
  "$VAULT_ADDR/v1/secret/data/admin/backup-key")
echo "   HTTP $CODE  (403 = permission denied, as expected)"
