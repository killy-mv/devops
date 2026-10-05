# Policy for the bakery app: least privilege, read only what it needs.
# Anything not listed is denied.

# Static secrets under secret/bakery/ (KV v2 puts "data/" in the API path)
path "secret/data/bakery/*" {
  capabilities = ["read"]
}

# Ask for a temporary database login
path "database/creds/bakery" {
  capabilities = ["read"]
}
