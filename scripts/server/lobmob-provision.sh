#!/bin/bash
set -euo pipefail

echo "=== lobmob provision: configuring lobboss ==="

# Validate secrets exist
source /etc/lobmob/secrets.env 2>/dev/null || { echo "ERROR: /etc/lobmob/secrets.env not found"; exit 1; }
for VAR in DO_TOKEN DISCORD_BOT_TOKEN ANTHROPIC_API_KEY; do
  if [ -z "${!VAR:-}" ]; then
    echo "ERROR: $VAR not set in secrets.env"
    exit 1
  fi
done
# GH_TOKEN is optional if GitHub App is configured
if [ -z "${GH_TOKEN:-}" ] && [ ! -f /etc/lobmob/gh-app.pem ]; then
  echo "ERROR: Neither GH_TOKEN nor GitHub App PEM configured"
  exit 1
fi

# Validate deploy key
if [ ! -f /root/.ssh/vault_key ]; then
  echo "ERROR: /root/.ssh/vault_key not found"
  exit 1
fi
chmod 600 /root/.ssh/vault_key

# Activate WireGuard
if [ -f /etc/wireguard/wg0.conf ]; then
  wg-quick up wg0 2>/dev/null || true
  systemctl enable wg-quick@wg0
  echo "WireGuard: active"
else
  echo "ERROR: /etc/wireguard/wg0.conf not found -- was WG private key pushed?"
  exit 1
fi

# Authenticate GitHub CLI (prefer App token, fall back to PAT)
GH_AUTH_TOKEN=""
if command -v lobmob-gh-token >/dev/null 2>&1; then
  GH_AUTH_TOKEN=$(lobmob-gh-token 2>/dev/null || true)
fi
if [ -z "$GH_AUTH_TOKEN" ]; then
  GH_AUTH_TOKEN="$GH_TOKEN"
  echo "GitHub CLI: using PAT"
else
  echo "GitHub CLI: using App installation token"
fi
echo "$GH_AUTH_TOKEN" | gh auth login --with-token
gh auth setup-git
gh config set git_protocol https
echo "GitHub CLI: authenticated"

# Re-set git identity (gh auth setup-git clobbers .gitconfig)
git config --global user.name "lobboss"
git config --global user.email "lobboss@lobmob.swarm"

# Authenticate doctl
doctl auth init -t "$DO_TOKEN"
echo "doctl: authenticated"

# Clone vault repo
source /etc/lobmob/env

# Look up DO project ID and set in env (idempotent)
PROJECT_ID=$(doctl projects list --format ID,Name --no-header | awk -v name="$PROJECT_NAME" '$2 == name {print $1}')
if [ -n "$PROJECT_ID" ]; then
  if grep -q "^DO_PROJECT_ID=" /etc/lobmob/env 2>/dev/null; then
    sed -i "s|^DO_PROJECT_ID=.*|DO_PROJECT_ID=$PROJECT_ID|" /etc/lobmob/env
  else
    echo "DO_PROJECT_ID=$PROJECT_ID" >> /etc/lobmob/env
  fi
  echo "DO project: $PROJECT_ID"
fi
if [ ! -d /opt/vault/.git ]; then
  gh repo clone "$VAULT_REPO" /opt/vault
  cd /opt/vault && git checkout main
  echo "Vault: cloned"
else
  cd /opt/vault && git stash 2>/dev/null || true
  git pull origin main --rebase 2>/dev/null || true
  git stash pop 2>/dev/null || true
  echo "Vault: updated"
fi

# Configure OpenClaw
mkdir -p /root/.openclaw/skills

# Run openclaw onboard (creates openclaw.json — but clobbers AGENTS.md with generic default)
timeout 30 openclaw onboard \
  --non-interactive --accept-risk --workspace /opt/vault 2>/dev/null || true

# Restore coordinator AGENTS.md (openclaw onboard overwrites with generic assistant)
if [ -f /opt/vault/040-fleet/lobboss-AGENTS.md ]; then
  cp /opt/vault/040-fleet/lobboss-AGENTS.md /opt/vault/AGENTS.md
  echo "Vault AGENTS.md: restored coordinator persona"
fi

# Create .env
echo "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY" > /root/.openclaw/.env
chmod 600 /root/.openclaw/.env

# Ensure openclaw.json exists (fallback if onboard hung)
if [ ! -f /root/.openclaw/openclaw.json ]; then
  GW_TOKEN=$(openssl rand -hex 24)
  echo "{\"gateway\":{\"port\":18789,\"mode\":\"local\",\"bind\":\"loopback\",\"auth\":{\"mode\":\"token\",\"token\":\"$GW_TOKEN\"}}}" > /root/.openclaw/openclaw.json
fi

# Patch openclaw.json with Discord channels + agent config
# Note: don't include gateway block -- openclaw onboard already sets it with auth token
jq --arg token "$DISCORD_BOT_TOKEN" '{
  channels: { discord: { enabled: true, token: $token, groupPolicy: "allowlist",
    guilds: { "467002962456084481": { slug: "mattcave", requireMention: false,
reactionNotifications: "own",
channels: { "'"${DISCORD_CHANNEL_TASK_QUEUE:-task-queue}"'": {allow:true}, "'"${DISCORD_CHANNEL_SWARM_CONTROL:-swarm-control}"'": {allow:true}, "'"${DISCORD_CHANNEL_SWARM_LOGS:-swarm-logs}"'": {allow:true} }
    }}
  }},
  agents: { defaults: { model: { primary: "anthropic/claude-sonnet-4-5" }, workspace: "/opt/vault" }}
} * .' /root/.openclaw/openclaw.json > /tmp/oc.tmp && mv /tmp/oc.tmp /root/.openclaw/openclaw.json

# Remove old config.json if it exists
rm -f /root/.openclaw/config.json

# Deploy lobboss skills from vault (clear stale, copy fresh)
rm -rf /root/.openclaw/skills/*
cp -r /opt/vault/040-fleet/lobboss-skills/* /root/.openclaw/skills/ 2>/dev/null || true
echo "Skills: $(ls /root/.openclaw/skills/ | wc -l) deployed"

# Deploy lobboss AGENTS.md from vault
cp /opt/vault/040-fleet/lobboss-AGENTS.md /root/.openclaw/AGENTS.md 2>/dev/null || true

# Clear stale agent sessions (skills may have changed)
rm -rf /root/.openclaw/agents/main/sessions/* 2>/dev/null || true

# Generate SSH keypair for lobboss -> lobster connections
if [ ! -f /root/.ssh/lobster_admin ]; then
  ssh-keygen -t ed25519 -C "lobboss-to-lobster" -f /root/.ssh/lobster_admin -N "" -q
  echo "SSH keypair for lobster access: generated"
fi

# Write systemd service for OpenClaw gateway
cat > /etc/systemd/system/openclaw-gateway.service <<'SVCEOF'
[Unit]
Description=OpenClaw Gateway
After=network.target wg-quick@wg0.service
Wants=wg-quick@wg0.service

[Service]
Type=simple
WorkingDirectory=/opt/vault
EnvironmentFile=/root/.openclaw/.env
ExecStart=/usr/bin/env openclaw gateway --port 18789
Restart=on-failure
RestartSec=10
StandardOutput=append:/var/log/openclaw-gateway.log
StandardError=append:/var/log/openclaw-gateway.log

[Install]
WantedBy=multi-user.target
SVCEOF
systemctl daemon-reload
systemctl enable openclaw-gateway
systemctl start openclaw-gateway

echo "OpenClaw: configured and gateway started"

# Start web UI if web.env exists (OAuth configured)
if [ -f /etc/lobmob/web.env ]; then
  systemctl daemon-reload
  systemctl enable lobmob-web
  systemctl start lobmob-web
  echo "Web UI: started on port 8080"

  # Add DO token refresh cron (every 25 days)
  if ! grep -q lobmob-refresh-do-token /etc/crontab 2>/dev/null; then
    echo "0 0 */25 * * root /usr/local/bin/lobmob-refresh-do-token >> /var/log/lobmob-token-refresh.log 2>&1" >> /etc/crontab
  fi
fi

# Remove provision marker
rm -f /etc/lobmob/.awaiting-secrets

echo "=== lobmob provision: complete ==="
