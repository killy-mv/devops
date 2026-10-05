#!/bin/sh
set -e

# Create the SSH key pair the servers will trust (once; kept in the ssh-keys volume)
[ -f /keys/id_ed25519 ] || ssh-keygen -t ed25519 -N '' -C ansible-demo -f /keys/id_ed25519

# Stay alive so you can `docker compose exec control ...`
exec sleep infinity
