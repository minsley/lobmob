ARG BASE_IMAGE=lobmob-base
FROM ${BASE_IMAGE}

# GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Source
COPY src/lobboss/ /app/lobboss/
COPY src/common/ /app/common/

# Skills
COPY skills/lobboss/ /app/skills/

# Web dashboard
COPY scripts/server/lobmob-web.js /app/scripts/lobmob-web.js

# Cron scripts (used by k8s CronJobs)
COPY scripts/server/container-env.sh \
     scripts/server/lobmob-task-manager.sh \
     scripts/server/lobmob-review-prs.sh \
     scripts/server/lobmob-status-reporter.sh \
     scripts/server/lobmob-flush-logs.sh \
     scripts/server/lobmob-log.sh \
     /app/scripts/
RUN chmod +x /app/scripts/*.sh

ENTRYPOINT ["python", "-m", "lobboss.bot"]

LABEL org.opencontainers.image.description="lobmob lobboss — Discord bot + Agent SDK coordinator"
