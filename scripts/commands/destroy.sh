warn "This will destroy ALL lobmob infrastructure (lobboss + VPC + firewalls)"
read -rp "Are you sure? [y/N] " confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
  cmd_teardown_all 2>/dev/null || true
  load_secrets
  cd "$INFRA_DIR" && terraform destroy -auto-approve
  log "All infrastructure destroyed"
fi
