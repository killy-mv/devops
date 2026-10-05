#!/bin/sh
set -e

# Wait for the control node to create its key, then trust it for user "ansible"
until [ -f /keys/id_ed25519.pub ]; do sleep 1; done
install -d -m 700 -o ansible -g ansible /home/ansible/.ssh
install -m 600 -o ansible -g ansible /keys/id_ed25519.pub /home/ansible/.ssh/authorized_keys

exec /usr/sbin/sshd -D -e
