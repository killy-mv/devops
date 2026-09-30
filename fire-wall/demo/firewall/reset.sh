#!/bin/sh
# Remove all rules and allow everything (the state the server starts in).
# Run with: docker compose exec server sh /firewall/reset.sh
iptables -P INPUT ACCEPT
iptables -P OUTPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -F
iptables -X

echo "Firewall OFF (everything allowed)"
