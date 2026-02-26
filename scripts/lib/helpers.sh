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


push_k8s_secrets() {
  # Push lobmob-secrets and lobwife-secrets to k8s (idempotent)
  # Requires: load_secrets called first, KUBE_CONTEXT set
  local args=()
  [[ -n "${ANTHROPIC_API_KEY:-}" ]] && args+=(--from-literal="ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}")
  [[ -n "${DISCORD_BOT_TOKEN:-}" ]] && args+=(--from-literal="DISCORD_BOT_TOKEN=${DISCORD_BOT_TOKEN}")
  [[ -n "${GH_TOKEN:-}" ]] && args+=(--from-literal="GH_TOKEN=${GH_TOKEN}")
  [[ -n "${GEMINI_API_KEY:-}" ]] && args+=(--from-literal="GEMINI_API_KEY=${GEMINI_API_KEY}")
  if [[ ${#args[@]} -gt 0 ]]; then
    kubectl --context "$KUBE_CONTEXT" -n lobmob create secret generic lobmob-secrets \
      "${args[@]}" --dry-run=client -o yaml | kubectl --context "$KUBE_CONTEXT" apply -f -
    log "lobmob-secrets synced (${#args[@]} keys)"
  fi

  local broker_args=()
  [[ -n "${GH_APP_ID:-}" ]] && broker_args+=(--from-literal="GH_APP_ID=${GH_APP_ID}")
  [[ -n "${GH_APP_INSTALL_ID:-}" ]] && broker_args+=(--from-literal="GH_APP_INSTALL_ID=${GH_APP_INSTALL_ID}")
  # secrets.env stores as GH_APP_PEM_B64, daemon expects GH_APP_PEM (base64-encoded)
  [[ -n "${GH_APP_PEM_B64:-}" ]] && broker_args+=(--from-literal="GH_APP_PEM=${GH_APP_PEM_B64}")
  if [[ ${#broker_args[@]} -gt 0 ]]; then
    kubectl --context "$KUBE_CONTEXT" -n lobmob create secret generic lobwife-secrets \
      "${broker_args[@]}" --dry-run=client -o yaml | kubectl --context "$KUBE_CONTEXT" apply -f -
    log "lobwife-secrets synced (${#broker_args[@]} keys)"
  fi
}

require_local_deps() {
  # Ensure Docker (via Colima) and k3d are available for local dev.
  # Auto-installs via brew and starts Colima if needed.
  if ! command -v brew &>/dev/null; then
    err "Homebrew not found. Install from https://brew.sh"
    return 1
  fi

  # Docker CLI
  if ! command -v docker &>/dev/null; then
    log "Installing docker via brew..."
    brew install docker || { err "Failed to install docker"; return 1; }
  fi

  # Colima (lightweight Docker runtime for macOS)
  if ! command -v colima &>/dev/null; then
    log "Installing colima via brew..."
    brew install colima || { err "Failed to install colima"; return 1; }
  fi

  # Start Colima if Docker daemon isn't reachable
  if ! docker info &>/dev/null 2>&1; then
    log "Starting colima..."
    colima start || { err "Failed to start colima"; return 1; }
  fi

  # k3d
  if ! command -v k3d &>/dev/null; then
    log "Installing k3d via brew..."
    brew install k3d || { err "Failed to install k3d"; return 1; }
  fi
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
  git add -A
  git commit -m "Add skills for fleet distribution" 2>/dev/null || true
  git push origin main 2>/dev/null || git push -u origin main 2>/dev/null || true
  rm -rf "$TMPDIR"
  cd "$PROJECT_DIR"
}
