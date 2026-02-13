ARG BASE_IMAGE=lobmob-base
FROM ${BASE_IMAGE}

# GitHub CLI (needed for PR creation)
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Source
COPY src/lobster/ /app/lobster/
COPY src/common/ /app/common/

# Skills
COPY skills/lobster/ /app/skills/

# Lobster prompts
COPY src/lobster/prompts/ /app/lobster/prompts/

ENTRYPOINT ["python", "-m", "lobster.run_task"]

LABEL org.opencontainers.image.description="lobmob lobster — ephemeral Agent SDK task worker"
