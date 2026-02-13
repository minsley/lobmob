ARG BASE_IMAGE=lobmob-base
FROM ${BASE_IMAGE}

# GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# doctl (DigitalOcean CLI — used by cron scripts)
RUN curl -fsSL "https://github.com/digitalocean/doctl/releases/latest/download/doctl-$(curl -fsSL https://api.github.com/repos/digitalocean/doctl/releases/latest | jq -r .tag_name | tr -d v)-linux-$(dpkg --print-architecture).tar.gz" \
    | tar xz -C /usr/local/bin

# Source
COPY src/lobboss/ /app/lobboss/
COPY src/common/ /app/common/

# Skills
COPY skills/lobboss/ /app/skills/

# Cron scripts (used by k8s CronJobs — packaged here for image reuse)
COPY scripts/server/container-env.sh \
     scripts/server/lobmob-task-manager.sh \
     scripts/server/lobmob-watchdog.sh \
     scripts/server/lobmob-review-prs.sh \
     scripts/server/lobmob-status-reporter.sh \
     scripts/server/lobmob-pool-manager.sh \
     scripts/server/lobmob-gh-token.sh \
     scripts/server/lobmob-flush-logs.sh \
     scripts/server/lobmob-fleet-status.sh \
     scripts/server/lobmob-cleanup.sh \
     scripts/server/lobmob-log.sh \
     /app/scripts/
RUN chmod +x /app/scripts/*.sh

ENTRYPOINT ["python", "-m", "lobboss.bot"]

LABEL org.opencontainers.image.description="lobmob lobboss — Discord bot + Agent SDK coordinator"
