#!/usr/bin/env bash
# Container environment wrapper for cron scripts.
# Sources this file at the top of each script when running in k8s.
# Maps k8s-injected env vars to the paths/vars scripts expect.
set -euo pipefail

# Detect if we're in a container (k8s pod) vs bare Droplet
if [[ -f /var/run/secrets/kubernetes.io/serviceaccount/token ]]; then
    export LOBMOB_RUNTIME="k8s"
else
    export LOBMOB_RUNTIME="droplet"
fi

# Vault path — same in both environments
export VAULT_PATH="${VAULT_PATH:-/opt/vault}"

# Environment
export LOBMOB_ENV="${LOBMOB_ENV:-prod}"

# Secrets are injected as env vars in k8s (via Secret), or sourced from file on Droplet
if [[ "$LOBMOB_RUNTIME" == "droplet" ]]; then
    [[ -f /etc/lobmob/env ]] && source /etc/lobmob/env
    [[ -f /etc/lobmob/secrets.env ]] && source /etc/lobmob/secrets.env
fi
# In k8s, secrets are already in env via envFrom in the CronJob spec.

# Log helper — scripts use lobmob-log, ensure it's on PATH
export PATH="/app/scripts:${PATH}"

# GitHub App PEM — on Droplet it's a file, in k8s it's a Secret mount
if [[ "$LOBMOB_RUNTIME" == "k8s" ]]; then
    export GH_APP_PEM_PATH="${GH_APP_PEM_PATH:-/run/secrets/gh-app.pem}"
else
    export GH_APP_PEM_PATH="${GH_APP_PEM_PATH:-/etc/lobmob/gh-app.pem}"
fi

# Log file paths — in k8s use /tmp (emptyDir), on Droplet use /var/log
if [[ "$LOBMOB_RUNTIME" == "k8s" ]]; then
    export LOG_DIR="/tmp"
    export TASK_STATE_DIR="/tmp/lobmob-task-state"
else
    export LOG_DIR="/var/log"
    export TASK_STATE_DIR="/var/lib/lobmob/task-state"
fi
