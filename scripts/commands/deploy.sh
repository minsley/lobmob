# lobmob deploy — apply Terraform + k8s manifests

load_secrets

log "Deploying lobmob ($LOBMOB_ENV)..."
cd "$INFRA_DIR"

# Workspace mapping: prod uses 'default' workspace (legacy), dev uses 'dev'
if [[ "$LOBMOB_ENV" == "prod" ]]; then
  terraform workspace select default 2>/dev/null || true
else
  terraform workspace select "$LOBMOB_ENV" 2>/dev/null || terraform workspace new "$LOBMOB_ENV"
fi

terraform plan -var-file="$TFVARS_FILE" -out=tfplan
echo ""
read -rp "Apply this plan? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  log "Cancelled"
  exit 0
fi

terraform apply tfplan

# Apply k8s manifests
if [[ "$LOBMOB_ENV" == "dev" ]]; then
  KUBE_CONTEXT="do-nyc3-lobmob-dev-k8s"
  OVERLAY="dev"
else
  KUBE_CONTEXT="do-nyc3-lobmob-k8s"
  OVERLAY="prod"
fi

log "Applying k8s manifests (overlay=$OVERLAY)..."
kubectl --context "$KUBE_CONTEXT" apply -k "$PROJECT_DIR/k8s/overlays/$OVERLAY/"

log "Syncing k8s secrets..."
push_k8s_secrets

log ""
log "Deployed. Check status with: lobmob status"
