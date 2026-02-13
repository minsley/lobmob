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
