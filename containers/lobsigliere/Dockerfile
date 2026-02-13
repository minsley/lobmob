ARG BASE_IMAGE=ghcr.io/minsley/lobmob-base:latest
FROM ${BASE_IMAGE}

# Ops tooling
RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-server tmux vim less man-db sudo \
    unzip wget apt-transport-https gnupg lsb-release curl \
    && rm -rf /var/lib/apt/lists/*

# Terraform
RUN wget -qO- https://apt.releases.hashicorp.com/gpg | gpg --dearmor > /usr/share/keyrings/hashicorp.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/hashicorp.list \
    && apt-get update && apt-get install -y terraform \
    && rm -rf /var/lib/apt/lists/*

# kubectl (direct binary — k8s apt repo signing key rejected by Debian Trixie sqv)
RUN curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/v1.31.4/bin/linux/amd64/kubectl" \
    && chmod +x /usr/local/bin/kubectl

# GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# lobmob source + CLI
COPY . /opt/lobmob
RUN ln -s /opt/lobmob/scripts/lobmob /usr/local/bin/lobmob

# SSH setup
RUN mkdir -p /run/sshd
COPY containers/lobsigliere/sshd_config /etc/ssh/sshd_config

# Engineer user
RUN useradd -m -s /bin/bash -G sudo engineer \
    && passwd -d engineer \
    && echo "engineer ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/engineer \
    && chmod 440 /etc/sudoers.d/engineer \
    && mkdir -p /home/engineer/.ssh && chmod 700 /home/engineer/.ssh \
    && chown -R engineer:engineer /home/engineer/.ssh

COPY containers/lobsigliere/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22

ENTRYPOINT ["/entrypoint.sh"]
