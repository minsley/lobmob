# lobmob destroy — tear down infrastructure

warn "This will destroy lobmob infrastructure ($LOBMOB_ENV)"
read -rp "Are you sure? [y/N] " confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
  load_secrets
  cd "$INFRA_DIR"
  if [[ "$LOBMOB_ENV" == "prod" ]]; then
    terraform workspace select default 2>/dev/null || true
  else
    terraform workspace select "$LOBMOB_ENV" 2>/dev/null || true
  fi
  terraform destroy -var-file="$TFVARS_FILE"
  log "Infrastructure destroyed"
fi
