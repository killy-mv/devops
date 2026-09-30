#!/bin/sh
# Host firewall for the server. Run with: docker compose exec server sh /firewall/rules.sh
# Rules are checked top to bottom; the first match wins. The policy (-P) applies when nothing matches.
set -e

OFFICE_IP=172.29.10.20

# Start clean. Only the filter table is touched: Docker's DNS rules live in the nat table.
iptables -F
iptables -X

# ---- Inbound: who may connect to this server ----
iptables -P INPUT DROP                                                    # default: deny
iptables -A INPUT -i lo -j ACCEPT                                         # apps on this server talking to each other
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT    # replies to connections we started
iptables -A INPUT -p icmp -j ACCEPT                                       # ping
iptables -A INPUT -p tcp --dport 80 -j ACCEPT                             # web: everyone
iptables -A INPUT -p tcp --dport 9000 -s "$OFFICE_IP" -j ACCEPT           # admin: office only
# db (6379): no rule, so the DROP policy blocks it

# ---- Outbound: where this server may connect to ----
iptables -P OUTPUT DROP                                                   # default: deny
iptables -A OUTPUT -o lo -j ACCEPT                                        # local traffic, incl. Docker's DNS (127.0.0.11)
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT   # replies to connections others started
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT                            # DNS lookups
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT                           # HTTPS only (e.g. calling an API)

# ---- Forwarding: this server is not a router ----
iptables -P FORWARD DROP

echo "Firewall ON"
iptables -L -n --line-numbers
