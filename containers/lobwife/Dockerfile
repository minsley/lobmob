ARG BASE_IMAGE=ghcr.io/minsley/lobmob-base:latest
FROM ${BASE_IMAGE}

# Ops tooling + SSH
RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-server tmux vim less sudo \
    && rm -rf /var/lib/apt/lists/*

# Python dependencies for scheduler daemon
COPY containers/lobwife/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt && rm /tmp/requirements.txt

# GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# lobmob source + CLI
COPY . /opt/lobmob
RUN ln -s /opt/lobmob/scripts/lobmob /usr/local/bin/lobmob

# SSH setup
RUN mkdir -p /run/sshd
COPY containers/lobwife/sshd_config /etc/ssh/sshd_config

# lobwife user (passwordless sudo, home on PVC)
RUN useradd -m -s /bin/bash -G sudo lobwife \
    && passwd -d lobwife \
    && echo "lobwife ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/lobwife \
    && chmod 440 /etc/sudoers.d/lobwife \
    && mkdir -p /home/lobwife/.ssh && chmod 700 /home/lobwife/.ssh \
    && chown -R lobwife:lobwife /home/lobwife/.ssh

COPY containers/lobwife/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22 8080

ENTRYPOINT ["/entrypoint.sh"]

LABEL org.opencontainers.image.description="lobmob lobwife — persistent cron scheduler with HTTP API"
