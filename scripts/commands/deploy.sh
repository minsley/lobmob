load_secrets

log "Deploying lobboss via Terraform ($LOBMOB_ENV)..."
cd "$INFRA_DIR"
terraform workspace select "$LOBMOB_ENV" 2>/dev/null || terraform workspace new "$LOBMOB_ENV"
terraform plan -var-file="$TFVARS_FILE" -out=tfplan
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
