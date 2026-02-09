load_secrets

log "Deploying lobboss via Terraform ($LOBMOB_ENV)..."
cd "$INFRA_DIR"

# Workspace mapping: prod uses 'default' workspace (legacy), dev uses 'dev'
if [ "$LOBMOB_ENV" = "prod" ]; then
  terraform workspace select default 2>/dev/null || true
else
  terraform workspace select "$LOBMOB_ENV" 2>/dev/null || terraform workspace new "$LOBMOB_ENV"
fi

# Support --replace flag for full redeploys
REPLACE_FLAG=""
if [ "${1:-}" = "--replace" ] || [ "${1:-}" = "--redeploy" ]; then
  REPLACE_FLAG="-replace=digitalocean_droplet.lobboss"
  log "Full redeploy requested — lobboss will be recreated"
fi

terraform plan -var-file="$TFVARS_FILE" $REPLACE_FLAG -out=tfplan
echo ""
read -rp "Apply this plan? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  log "Cancelled"
  return
fi

terraform apply tfplan
LOBBOSS_IP=$(terraform output -raw lobboss_ip)
log "Lobboss droplet created at $LOBBOSS_IP"

# Wait for SSH and cloud-init
wait_for_ssh "$LOBBOSS_IP"
wait_for_cloud_init "$LOBBOSS_IP"

# Push secrets
log "Provisioning secrets via SSH..."
cmd_provision_secrets_to "$LOBBOSS_IP"

log ""
log "Lobboss fully deployed and provisioned at $LOBBOSS_IP"
log "  SSH:    lobmob ssh-lobboss"
log "  Status: lobmob status"
