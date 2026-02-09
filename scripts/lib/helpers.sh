#!/bin/bash
# Shared helpers for lobmob CLI commands
# Sourced by the dispatcher and individual commands

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[lobmob]${NC} $*"; }
warn() { echo -e "${YELLOW}[lobmob]${NC} $*"; }
err()  { echo -e "${RED}[lobmob]${NC} $*" >&2; }

portable_sed_i() { if [[ "$OSTYPE" == "darwin"* ]]; then sed -i '' "$@"; else sed -i "$@"; fi; }

load_secrets() {
  if [ ! -f "$SECRETS_FILE" ]; then
    err "secrets.env not found at $SECRETS_FILE"
    err "Copy secrets.env.example to secrets.env and fill in values"
    exit 1
  fi
  set -a
  source "$SECRETS_FILE"
  set +a
  export DIGITALOCEAN_TOKEN="$DO_TOKEN"
}

lobmob_ssh() {
  ssh -i "$LOBMOB_SSH_KEY" -o StrictHostKeyChecking=accept-new "$@"
}

ensure_ssh_key() {
  if [ ! -f "$LOBMOB_SSH_KEY" ]; then
    log "Generating lobmob SSH keypair at $LOBMOB_SSH_KEY..."
    ssh-keygen -t ed25519 -C "lobmob" -f "$LOBMOB_SSH_KEY" -N "" -q
    echo -e "  ${GREEN}✓${NC} Keypair generated"
  fi

  if [ -f "$INFRA_DIR/terraform.tfvars" ]; then
    CURRENT_SSH_PATH=$(grep ssh_pub_key_path "$INFRA_DIR/terraform.tfvars" 2>/dev/null | cut -d'"' -f2)
    EXPECTED_SSH_PATH="${LOBMOB_SSH_KEY}.pub"
    if [ -n "$CURRENT_SSH_PATH" ] && [ "$CURRENT_SSH_PATH" != "$EXPECTED_SSH_PATH" ]; then
      warn "terraform.tfvars has ssh_pub_key_path=\"$CURRENT_SSH_PATH\""
      log "Updating to \"$EXPECTED_SSH_PATH\""
      portable_sed_i "s|ssh_pub_key_path.*|ssh_pub_key_path      = \"$EXPECTED_SSH_PATH\"|" "$INFRA_DIR/terraform.tfvars"
    fi
  fi
}

get_lobboss_ip() {
  # Workspace mapping: prod uses 'default' (legacy), dev uses 'dev'
  local ws="$LOBMOB_ENV"
  [ "$ws" = "prod" ] && ws="default"
  terraform -chdir="$INFRA_DIR" workspace select "$ws" 2>/dev/null || true
  terraform -chdir="$INFRA_DIR" output -raw lobboss_ip 2>/dev/null
}

get_lobboss_id() {
  local PROJECT_NAME
  PROJECT_NAME=$(grep project_name "$INFRA_DIR/terraform.tfvars" 2>/dev/null | cut -d'"' -f2)
  PROJECT_NAME="${PROJECT_NAME:-lobmob}"
  doctl compute droplet list \
    --tag-name "${PROJECT_NAME}-lobboss" \
    --format ID --no-header \
    --access-token "$DO_TOKEN" 2>/dev/null | head -1
}

wait_for_ssh() {
  local HOST="$1"
  local MAX_ATTEMPTS="${2:-30}"
  log "Waiting for SSH on $HOST..."
  for i in $(seq 1 "$MAX_ATTEMPTS"); do
    if lobmob_ssh -o ConnectTimeout=5 -o BatchMode=yes \
      "root@$HOST" "true" 2>/dev/null; then
      log "SSH: connected"
      return 0
    fi
    echo -n "."
    sleep 10
  done
  echo ""
  err "SSH connection to $HOST timed out after $((MAX_ATTEMPTS * 10))s"
  return 1
}

wait_for_cloud_init() {
  local HOST="$1"
  log "Waiting for cloud-init to complete on $HOST..."
  local CI_STATUS
  CI_STATUS=$(lobmob_ssh -o ConnectTimeout=10 "root@$HOST" \
    "cloud-init status --wait 2>/dev/null; cloud-init status --format=json 2>/dev/null || cloud-init status" 2>/dev/null) || true

  if echo "$CI_STATUS" | grep -qE '"(done|degraded)"' 2>/dev/null || \
     echo "$CI_STATUS" | grep -qE 'status: (done|degraded)' 2>/dev/null; then
    log "Cloud-init: complete"
    if echo "$CI_STATUS" | grep -q "degraded" 2>/dev/null; then
      warn "Cloud-init finished with warnings (degraded) -- non-fatal, continuing"
    fi
    return 0
  fi

  err "Cloud-init did not complete successfully"
  err "Status: $CI_STATUS"
  err "Check: lobmob ssh-lobboss then: tail -100 /var/log/cloud-init-output.log"
  return 1
}

_seed_vault() {
  local REPO="$1"
  local TMPDIR
  TMPDIR=$(mktemp -d)
  gh repo clone "$REPO" "$TMPDIR" 2>/dev/null || true
  if [ ! -d "$TMPDIR/.git" ]; then
    rm -rf "$TMPDIR"
    return 1
  fi
  cp -r "$PROJECT_DIR/vault-seed/"* "$TMPDIR/" 2>/dev/null || true
  cp -r "$PROJECT_DIR/vault-seed/".obsidian "$TMPDIR/" 2>/dev/null || true
  cp -r "$PROJECT_DIR/vault-seed/".gitattributes "$TMPDIR/" 2>/dev/null || true
  cd "$TMPDIR"
  git add -A
  git commit -m "Seed vault structure" 2>/dev/null || true
  mkdir -p 040-fleet/lobboss-skills 040-fleet/lobster-skills
  cp -r "$PROJECT_DIR/skills/lobboss/"* 040-fleet/lobboss-skills/ 2>/dev/null || true
  cp -r "$PROJECT_DIR/skills/lobster/"* 040-fleet/lobster-skills/ 2>/dev/null || true
  cp "$PROJECT_DIR/openclaw/lobboss/AGENTS.md" 040-fleet/lobboss-AGENTS.md 2>/dev/null || true
  cp "$PROJECT_DIR/openclaw/lobster/AGENTS.md" 040-fleet/lobster-AGENTS.md 2>/dev/null || true
  cp "$PROJECT_DIR/openclaw/lobster-swe/AGENTS.md" 040-fleet/lobster-swe-AGENTS.md 2>/dev/null || true
  cp "$PROJECT_DIR/openclaw/lobster-qa/AGENTS.md" 040-fleet/lobster-qa-AGENTS.md 2>/dev/null || true
  git add -A
  git commit -m "Add OpenClaw skills for fleet distribution" 2>/dev/null || true
  git push origin main 2>/dev/null || git push -u origin main 2>/dev/null || true
  rm -rf "$TMPDIR"
  cd "$PROJECT_DIR"
}
