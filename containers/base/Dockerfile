FROM python:3.12-slim

# System packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    jq \
    openssh-client \
    ca-certificates \
    gnupg \
    && rm -rf /var/lib/apt/lists/*

# Node.js 22 (required by Claude Agent SDK runtime)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Claude Code CLI (Agent SDK dependency)
RUN npm install -g @anthropic-ai/claude-code

# Python dependencies
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt && rm /tmp/requirements.txt

# Working directory
WORKDIR /app

# Common source
COPY src/common/ /app/common/

LABEL org.opencontainers.image.source="https://github.com/minsley/lobmob"
LABEL org.opencontainers.image.description="lobmob base image — Python + Node.js + Claude Agent SDK"
