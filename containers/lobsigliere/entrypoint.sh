#!/bin/bash
set -euo pipefail

# Generate SSH host keys if not already present (persisted on PVC)
if [[ ! -f /etc/ssh/ssh_host_ed25519_key ]]; then
    echo "Generating SSH host keys..."
    ssh-keygen -A
fi

# Clean PVC lost+found if present
rm -rf /home/engineer/lost+found

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

# Set up .bashrc with lobmob environment (idempotent)
if ! grep -q "lobmob environment" /home/engineer/.bashrc 2>/dev/null; then
cat >> /home/engineer/.bashrc <<'BASHRC'

# lobmob environment
export PATH="/opt/lobmob/scripts:${PATH}"
export LOBMOB_ENV="${LOBMOB_ENV:-dev}"

alias k="kubectl"
alias kn="kubectl -n lobmob"
alias kl="kubectl -n lobmob logs"
alias kp="kubectl -n lobmob get pods"
alias kj="kubectl -n lobmob get jobs"

echo "lobsigliere — lobmob remote operations console"
echo "  env:       ${LOBMOB_ENV:-dev}"
echo "  lobmob:    $(lobmob --version 2>/dev/null || echo 'available')"
echo "  kubectl:   $(kubectl version --client --short 2>/dev/null || echo 'available')"
echo "  terraform: $(terraform version -json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["terraform_version"])' 2>/dev/null || echo 'available')"
echo ""
BASHRC
fi

chown engineer:engineer /home/engineer/.bashrc

echo "Starting sshd..."
exec /usr/sbin/sshd -D -e
