# Slurm-web v6 (Rackslab packages). Official docs: Docker install is not supported yet;
# this image installs slurm-web-agent + slurm-web-gateway from pkgs.rackslab.io.
# https://docs.rackslab.io/slurm-web/install/install/containers/docker.html
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        util-linux \
    && curl -fsSL https://pkgs.rackslab.io/keyring.asc \
        | gpg --dearmor -o /usr/share/keyrings/rackslab.gpg \
    && printf '%s\n' \
        'Types: deb' \
        'URIs: https://pkgs.rackslab.io/deb' \
        'Suites: ubuntu24.04' \
        'Components: main slurmweb-6' \
        'Architectures: amd64' \
        'Signed-By: /usr/share/keyrings/rackslab.gpg' \
        > /etc/apt/sources.list.d/rackslab.sources \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        slurm-web-agent \
        slurm-web-gateway \
    && rm -rf /var/lib/apt/lists/*

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

VOLUME ["/var/lib/slurm-web"]

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
