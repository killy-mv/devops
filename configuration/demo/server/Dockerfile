# A "fresh server": SSH so Ansible can log in, Python so Ansible modules can run
# (python3-apt lets the apt module work in --check mode, like on most real Debian/Ubuntu servers).
FROM debian:bookworm-slim

# Package lists are kept (unlike most images) so --check mode can look packages up, like on a real server
RUN apt-get update \
 && apt-get install -y --no-install-recommends openssh-server python3 python3-apt sudo \
 && useradd -m -s /bin/bash ansible \
 && usermod -p '*' ansible \
 && echo 'ansible ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ansible \
 && mkdir -p /run/sshd

COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["sh", "/entrypoint.sh"]
