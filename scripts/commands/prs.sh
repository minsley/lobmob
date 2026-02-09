VAULT_REPO=$(grep vault_repo "$INFRA_DIR/terraform.tfvars" 2>/dev/null | cut -d'"' -f2)
if [ -z "$VAULT_REPO" ]; then
  err "vault_repo not found in terraform.tfvars"
  exit 1
fi
gh pr list --repo "$VAULT_REPO" --state open
