#!/bin/bash
set -euo pipefail

# Generate SSH host keys if not already present (persisted on PVC)
if [[ ! -f /etc/ssh/ssh_host_ed25519_key ]]; then
    echo "Generating SSH host keys..."
    ssh-keygen -A
fi

# Clean PVC lost+found if present
rm -rf /home/engineer/lost+found

# Fix home dir ownership (PVC mounts as root, sshd StrictModes requires user ownership)
chown engineer:engineer /home/engineer

# Ensure .ssh dir exists (PVC mount overwrites home dir from image build)
mkdir -p /home/engineer/.ssh
chmod 700 /home/engineer/.ssh
chown engineer:engineer /home/engineer/.ssh

# Copy authorized_keys from mounted secret if present
if [[ -f /run/secrets/ssh-authorized-keys/authorized_keys ]]; then
    cp /run/secrets/ssh-authorized-keys/authorized_keys /home/engineer/.ssh/authorized_keys
    chmod 600 /home/engineer/.ssh/authorized_keys
    chown engineer:engineer /home/engineer/.ssh/authorized_keys
fi

# Configure git for the engineer user
if [[ -n "${GIT_USER_NAME:-}" ]]; then
    su - engineer -c "git config --global user.name '${GIT_USER_NAME}'"
fi
if [[ -n "${GIT_USER_EMAIL:-}" ]]; then
    su - engineer -c "git config --global user.email '${GIT_USER_EMAIL}'"
fi
# Configure git to use gh CLI for credentials (broker-backed via gh-lobwife wrapper)
if [[ -n "${LOBWIFE_URL:-}" ]]; then
    # Fetch initial token for gh auth setup-git
    _INIT_TOKEN=""
    for _i in 1 2 3 4 5; do
        _INIT_TOKEN=$(curl -sf -X POST "${LOBWIFE_URL}/api/v1/service-token" \
            -H "Content-Type: application/json" \
            -d '{"service":"lobsigliere"}' 2>/dev/null \
            | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])" 2>/dev/null) || true
        if [[ -n "$_INIT_TOKEN" ]]; then break; fi
        echo "Waiting for lobwife broker (attempt $_i/5)..."
        sleep 3
    done
    if [[ -n "$_INIT_TOKEN" ]]; then
        # Configure git to use our gh wrapper (not gh-real) so broker tokens flow through
        # Wipe ALL stale credential helpers first (PVC persists .gitconfig across restarts)
        su - engineer -c "git config --global --unset-all credential.helper" 2>/dev/null || true
        su - engineer -c "git config --global --unset-all credential.https://github.com.helper" 2>/dev/null || true
        su - engineer -c "git config --global --unset-all credential.https://gist.github.com.helper" 2>/dev/null || true
        su - engineer -c "git config --global credential.https://github.com.helper '!/usr/local/bin/gh auth git-credential'"
        echo "git credential helper configured (gh-lobwife wrapper)"
    else
        echo "WARNING: Could not get broker token, git auth may not work"
    fi
fi

# Clone lobmob repo into engineer's home (persistent on PVC)
LOBMOB_REPO="/home/engineer/lobmob"
if [[ -d "$LOBMOB_REPO/.git" ]]; then
    echo "Updating lobmob repo..."
    # Strip any baked-in credentials, gh auth handles auth now
    su - engineer -c "cd '$LOBMOB_REPO' && git remote set-url origin 'https://github.com/minsley/lobmob.git'" || true
    su - engineer -c "cd '$LOBMOB_REPO' && git fetch origin && git pull origin develop --rebase" || true
else
    echo "Cloning lobmob repo..."
    # Use broker service token for clone
    CLONE_TOKEN="${_INIT_TOKEN:-${LOBSIGLIERE_GH_TOKEN:-${GH_TOKEN:-}}}"
    if su - engineer -c "git clone 'https://x-access-token:${CLONE_TOKEN}@github.com/minsley/lobmob.git' '$LOBMOB_REPO'" 2>/dev/null; then
        # Strip credentials from remote — gh auth handles future operations
        su - engineer -c "cd '$LOBMOB_REPO' && git remote set-url origin 'https://github.com/minsley/lobmob.git'" || true
        su - engineer -c "cd '$LOBMOB_REPO' && git checkout develop" || true
    else
        echo "HTTPS clone failed. Clone manually after SSH in:"
        echo "  git clone git@github.com:minsley/lobmob.git ~/lobmob"
    fi
fi

# Clone vault repo into engineer's home (persistent on PVC, used by daemon)
VAULT_DIR="/home/engineer/vault"
LOBMOB_ENV="${LOBMOB_ENV:-prod}"
if [[ "$LOBMOB_ENV" == "dev" ]]; then
    VAULT_REPO_NAME="lobmob-vault-dev"
else
    VAULT_REPO_NAME="lobmob-vault"
fi
if [[ -d "$VAULT_DIR/.git" ]]; then
    echo "Updating vault repo..."
    # Strip any baked-in credentials, gh auth handles auth now
    su - engineer -c "cd '$VAULT_DIR' && git remote set-url origin 'https://github.com/minsley/${VAULT_REPO_NAME}.git'" || true
    su - engineer -c "cd '$VAULT_DIR' && git pull --rebase origin main" || true
else
    echo "Cloning vault repo..."
    # Use broker service token, fall back to env tokens
    CLONE_TOKEN="${_INIT_TOKEN:-${GH_TOKEN:-${LOBSIGLIERE_GH_TOKEN:-}}}"
    if su - engineer -c "git clone 'https://x-access-token:${CLONE_TOKEN}@github.com/minsley/${VAULT_REPO_NAME}.git' '$VAULT_DIR'" 2>/dev/null; then
        # Strip credentials from remote — gh auth handles future operations
        su - engineer -c "cd '$VAULT_DIR' && git remote set-url origin 'https://github.com/minsley/${VAULT_REPO_NAME}.git'" || true
    else
        echo "Vault clone failed — daemon will retry on startup"
    fi
fi

# Set up .bashrc with lobmob environment (idempotent)
if ! grep -q "lobmob environment" /home/engineer/.bashrc 2>/dev/null; then
# Interpolated section (bake in current env values)
cat >> /home/engineer/.bashrc <<ENVBLOCK

# lobmob environment
export LOBMOB_ENV="${LOBMOB_ENV:-dev}"
export KUBERNETES_SERVICE_HOST="${KUBERNETES_SERVICE_HOST:-}"
export KUBERNETES_SERVICE_PORT="${KUBERNETES_SERVICE_PORT:-443}"
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
export SERVICE_NAME="${SERVICE_NAME:-lobsigliere}"
export LOBWIFE_URL="${LOBWIFE_URL:-}"
ENVBLOCK

# Literal section (no interpolation)
cat >> /home/engineer/.bashrc <<'BASHRC'
export PATH="/opt/lobmob/scripts:${HOME}/lobmob/scripts:${PATH}"

alias k="kubectl"
alias kn="kubectl -n lobmob"
alias kl="kubectl -n lobmob logs"
alias kp="kubectl -n lobmob get pods"
alias kj="kubectl -n lobmob get jobs"

echo "lobsigliere — lobmob remote operations console"
echo "  env:       ${LOBMOB_ENV}"
echo "  repo:      ~/lobmob ($(cd ~/lobmob && git branch --show-current 2>/dev/null || echo '?'))"
echo "  claude:    $(test -n "$ANTHROPIC_API_KEY" && echo 'API key set' || echo 'no API key')"
echo "  kubectl:   $(kubectl version --client --short 2>/dev/null || kubectl version --client 2>&1 | head -1)"
echo "  terraform: $(terraform version 2>&1 | head -1)"
echo ""
BASHRC
fi

chown engineer:engineer /home/engineer/.bashrc

# Set up Claude Code CLI config for engineer user
mkdir -p /home/engineer/.claude
if [[ ! -f /home/engineer/.claude/CLAUDE.md ]]; then
    cp /opt/lobmob/containers/lobsigliere/CLAUDE.md /home/engineer/.claude/CLAUDE.md
fi
cat > /home/engineer/.claude/settings.json <<'JSON'
{
  "preferences": {
    "theme": "dark"
  }
}
JSON
chown -R engineer:engineer /home/engineer/.claude

# Start task processing daemon in background (runs as engineer)
echo "Starting lobsigliere task daemon..."
su - engineer -c "VAULT_PATH=/home/engineer/vault \
    SYSTEM_WORKSPACE=/home/engineer/lobmob \
    PYTHONPATH=/opt/lobmob/src \
    ANTHROPIC_API_KEY='${ANTHROPIC_API_KEY:-}' \
    SERVICE_NAME=lobsigliere \
    LOBWIFE_URL='${LOBWIFE_URL:-}' \
    LOBMOB_ENV='${LOBMOB_ENV:-prod}' \
    python3 /opt/lobmob/scripts/server/lobsigliere-daemon.py" &
DAEMON_PID=$!

# Cleanup handler — stop daemon when container exits
cleanup() {
    echo "Stopping daemon (PID $DAEMON_PID)..."
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
}
trap cleanup EXIT SIGTERM SIGINT

echo "Starting sshd..."
/usr/sbin/sshd -D -e &
SSHD_PID=$!

# Wait for either process to exit
wait -n "$DAEMON_PID" "$SSHD_PID" 2>/dev/null || true
echo "Process exited, shutting down..."
cleanup
