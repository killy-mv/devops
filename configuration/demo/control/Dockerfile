FROM python:3.12-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends openssh-client curl \
 && rm -rf /var/lib/apt/lists/* \
 && pip install --no-cache-dir "ansible-core==2.17.*"

WORKDIR /ansible
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["sh", "/entrypoint.sh"]
