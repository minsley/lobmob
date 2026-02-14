#!/bin/bash
set -euo pipefail

# Generate SSH host keys if not already present (persisted on PVC)
if [[ ! -f /etc/ssh/ssh_host_ed25519_key ]]; then
    echo "Generating SSH host keys..."
    ssh-keygen -A
fi

# Clean PVC lost+found if present
rm -rf /home/lobwife/lost+found

# Fix home dir ownership (PVC mounts as root, sshd StrictModes requires user ownership)
chown lobwife:lobwife /home/lobwife

# Ensure .ssh dir exists (PVC mount overwrites home dir from image build)
mkdir -p /home/lobwife/.ssh
chmod 700 /home/lobwife/.ssh
chown lobwife:lobwife /home/lobwife/.ssh

# Copy authorized_keys from mounted secret if present
if [[ -f /run/secrets/ssh-authorized-keys/authorized_keys ]]; then
    cp /run/secrets/ssh-authorized-keys/authorized_keys /home/lobwife/.ssh/authorized_keys
    chmod 600 /home/lobwife/.ssh/authorized_keys
    chown lobwife:lobwife /home/lobwife/.ssh/authorized_keys
fi

# Configure git for the lobwife user
if [[ -n "${GIT_USER_NAME:-}" ]]; then
    su - lobwife -c "git config --global user.name '${GIT_USER_NAME}'"
fi
if [[ -n "${GIT_USER_EMAIL:-}" ]]; then
    su - lobwife -c "git config --global user.email '${GIT_USER_EMAIL}'"
fi

# Clone/update lobmob repo (persistent on PVC, scripts live here)
LOBMOB_REPO="/home/lobwife/lobmob"
if [[ -d "$LOBMOB_REPO/.git" ]]; then
    echo "Updating lobmob repo..."
    su - lobwife -c "cd '$LOBMOB_REPO' && git fetch origin && git pull origin develop --rebase" || true
else
    echo "Cloning lobmob repo..."
    CLONE_TOKEN="${GH_TOKEN:-}"
    if su - lobwife -c "git clone 'https://x-access-token:${CLONE_TOKEN}@github.com/minsley/lobmob.git' '$LOBMOB_REPO'" 2>/dev/null; then
        su - lobwife -c "cd '$LOBMOB_REPO' && git checkout develop" || true
    else
        echo "HTTPS clone failed (token may not have repo access). Clone manually after SSH in:"
        echo "  git clone git@github.com:minsley/lobmob.git ~/lobmob"
    fi
fi

# Clone/update vault repo (persistent on PVC, used by cron scripts)
VAULT_DIR="/home/lobwife/vault"
if [[ -d "$VAULT_DIR/.git" ]]; then
    echo "Updating vault repo..."
    su - lobwife -c "cd '$VAULT_DIR' && git pull --rebase origin main" || true
else
    echo "Cloning vault repo..."
    CLONE_TOKEN="${GH_TOKEN:-}"
    LOBMOB_ENV="${LOBMOB_ENV:-prod}"
    if [[ "$LOBMOB_ENV" == "dev" ]]; then
        VAULT_REPO_NAME="lobmob-vault-dev"
    else
        VAULT_REPO_NAME="lobmob-vault"
    fi
    su - lobwife -c "git clone 'https://x-access-token:${CLONE_TOKEN}@github.com/minsley/${VAULT_REPO_NAME}.git' '$VAULT_DIR'" 2>/dev/null || \
        echo "Vault clone failed — daemon will retry on startup"
fi

# Create state directory (persistent on PVC)
mkdir -p /home/lobwife/state
chown lobwife:lobwife /home/lobwife/state

# Set up .bashrc with lobwife environment (idempotent)
if ! grep -q "lobwife environment" /home/lobwife/.bashrc 2>/dev/null; then
# Interpolated section (bake in current env values)
cat >> /home/lobwife/.bashrc <<ENVBLOCK

# lobwife environment
export LOBMOB_ENV="${LOBMOB_ENV:-prod}"
export KUBERNETES_SERVICE_HOST="${KUBERNETES_SERVICE_HOST:-}"
export KUBERNETES_SERVICE_PORT="${KUBERNETES_SERVICE_PORT:-443}"
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
export GH_TOKEN="${GH_TOKEN:-}"
ENVBLOCK

# Literal section (no interpolation)
cat >> /home/lobwife/.bashrc <<'BASHRC'
export PATH="/opt/lobmob/scripts:${HOME}/lobmob/scripts:${PATH}"
export VAULT_PATH="${HOME}/vault"

alias k="kubectl"
alias kn="kubectl -n lobmob"
alias kl="kubectl -n lobmob logs"
alias kp="kubectl -n lobmob get pods"
alias kj="kubectl -n lobmob get jobs"

echo "lobwife — lobmob persistent cron service"
echo "  env:     ${LOBMOB_ENV}"
echo "  repo:    ~/lobmob ($(cd ~/lobmob && git branch --show-current 2>/dev/null || echo '?'))"
echo "  vault:   ~/vault"
echo "  daemon:  $(pgrep -f lobwife-daemon > /dev/null 2>&1 && echo 'running' || echo 'stopped')"
echo "  web ui:  http://localhost:8080"
echo ""
BASHRC
fi

chown lobwife:lobwife /home/lobwife/.bashrc

# Set up Claude Code CLI config
mkdir -p /home/lobwife/.claude
if [[ ! -f /home/lobwife/.claude/CLAUDE.md ]]; then
    cp /opt/lobmob/containers/lobwife/CLAUDE.md /home/lobwife/.claude/CLAUDE.md
fi
cat > /home/lobwife/.claude/settings.json <<'JSON'
{
  "preferences": {
    "theme": "dark"
  }
}
JSON
chown -R lobwife:lobwife /home/lobwife/.claude

# Start lobwife daemon in background (runs as lobwife user)
echo "Starting lobwife daemon..."
su - lobwife -c "VAULT_PATH=/home/lobwife/vault \
    LOBMOB_ENV='${LOBMOB_ENV:-prod}' \
    GH_TOKEN='${GH_TOKEN:-}' \
    GH_APP_ID='${GH_APP_ID:-}' \
    GH_APP_INSTALL_ID='${GH_APP_INSTALL_ID:-}' \
    GH_APP_PEM='${GH_APP_PEM:-}' \
    ANTHROPIC_API_KEY='${ANTHROPIC_API_KEY:-}' \
    DISCORD_BOT_TOKEN='${DISCORD_BOT_TOKEN:-}' \
    KUBERNETES_SERVICE_HOST='${KUBERNETES_SERVICE_HOST:-}' \
    KUBERNETES_SERVICE_PORT='${KUBERNETES_SERVICE_PORT:-443}' \
    TASK_QUEUE_CHANNEL_ID='${TASK_QUEUE_CHANNEL_ID:-}' \
    SWARM_CONTROL_CHANNEL_ID='${SWARM_CONTROL_CHANNEL_ID:-}' \
    SWARM_LOGS_CHANNEL_ID='${SWARM_LOGS_CHANNEL_ID:-}' \
    python3 /opt/lobmob/scripts/server/lobwife-daemon.py \
    >> /home/lobwife/state/daemon.log 2>&1" &
DAEMON_PID=$!

# Start web dashboard in background
echo "Starting lobwife web dashboard..."
su - lobwife -c "node /opt/lobmob/scripts/server/lobwife-web.js \
    >> /home/lobwife/state/web.log 2>&1" &
WEB_PID=$!

# Cleanup handler — stop processes when container exits
cleanup() {
    echo "Stopping lobwife processes..."
    kill "$WEB_PID" 2>/dev/null || true
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$WEB_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
}
trap cleanup EXIT SIGTERM SIGINT

echo "Starting sshd..."
/usr/sbin/sshd -D -e &
SSHD_PID=$!

# Wait for any process to exit
wait -n "$DAEMON_PID" "$WEB_PID" "$SSHD_PID" 2>/dev/null || true
echo "Process exited, shutting down..."
cleanup
