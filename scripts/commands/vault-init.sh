log "Initializing vault repo..."

if [ -z "${VAULT_REPO:-}" ]; then
  # Try to read from terraform.tfvars
  VAULT_REPO=$(grep vault_repo "$INFRA_DIR/terraform.tfvars" 2>/dev/null | cut -d'"' -f2 || true)
fi
if [ -z "${VAULT_REPO:-}" ]; then
  read -rp "Vault repo (org/name): " VAULT_REPO
fi

gh repo create "$VAULT_REPO" --private --description "lobmob swarm Obsidian vault"
_seed_vault "$VAULT_REPO"
log "Vault repo created: $VAULT_REPO"
