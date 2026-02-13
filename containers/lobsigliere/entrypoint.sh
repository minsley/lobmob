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

# Clone lobmob repo into engineer's home (persistent on PVC)
LOBMOB_REPO="/home/engineer/lobmob"
if [[ -d "$LOBMOB_REPO/.git" ]]; then
    echo "Updating lobmob repo..."
    su - engineer -c "cd '$LOBMOB_REPO' && git fetch origin && git pull origin develop --rebase" || true
else
    echo "Cloning lobmob repo..."
    # Use LOBSIGLIERE_GH_TOKEN (scoped to lobmob repo), fall back to GH_TOKEN
    CLONE_TOKEN="${LOBSIGLIERE_GH_TOKEN:-${GH_TOKEN:-}}"
    if su - engineer -c "git clone 'https://x-access-token:${CLONE_TOKEN}@github.com/minsley/lobmob.git' '$LOBMOB_REPO'" 2>/dev/null; then
        su - engineer -c "cd '$LOBMOB_REPO' && git checkout develop" || true
    else
        echo "HTTPS clone failed (token may not have repo access). Clone manually after SSH in:"
        echo "  git clone git@github.com:minsley/lobmob.git ~/lobmob"
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
export GH_TOKEN="${LOBSIGLIERE_GH_TOKEN:-${GH_TOKEN:-}}"
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

echo "Starting sshd..."
exec /usr/sbin/sshd -D -e
