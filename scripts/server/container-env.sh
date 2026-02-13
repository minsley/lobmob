#!/usr/bin/env bash
# Container environment wrapper for cron scripts.
# Sources this file at the top of each script when running in k8s.
# Maps k8s-injected env vars to the paths/vars scripts expect.
set -euo pipefail

export LOBMOB_RUNTIME="k8s"

# Vault path
export VAULT_PATH="${VAULT_PATH:-/opt/vault}"

# Environment
export LOBMOB_ENV="${LOBMOB_ENV:-prod}"

# Secrets are injected as env vars via envFrom in the CronJob spec.

# Log helper — scripts use lobmob-log, ensure it's on PATH
export PATH="/app/scripts:${PATH}"

# GitHub App PEM — mounted as a Secret
export GH_APP_PEM_PATH="${GH_APP_PEM_PATH:-/run/secrets/gh-app.pem}"

# Log/state paths — use /tmp (emptyDir in k8s)
export LOG_DIR="/tmp"
export TASK_STATE_DIR="/tmp/lobmob-task-state"
