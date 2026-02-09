if [ -d "$PROJECT_DIR/vault-local" ]; then
  cd "$PROJECT_DIR/vault-local" && git pull origin main
else
  VAULT_REPO=$(grep vault_repo "$INFRA_DIR/terraform.tfvars" 2>/dev/null | cut -d'"' -f2)
  gh repo clone "$VAULT_REPO" "$PROJECT_DIR/vault-local"
fi
log "Vault synced to $PROJECT_DIR/vault-local/"
