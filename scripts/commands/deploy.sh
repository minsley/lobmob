# lobmob deploy — apply Terraform + k8s manifests

load_secrets

log "Deploying lobmob ($LOBMOB_ENV)..."

# Kube context + overlay (needed for pre-terraform scale-down)
if [[ "$LOBMOB_ENV" == "dev" ]]; then
  KUBE_CONTEXT="do-nyc3-lobmob-dev-k8s"
  OVERLAY="dev"
else
  KUBE_CONTEXT="do-nyc3-lobmob-k8s"
  OVERLAY="prod"
fi

# --- Terraform ---

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

# Scale down running deployments before terraform changes nodes.
# Skip if the cluster isn't reachable yet (fresh deploy).
DEPLOYMENTS=("lobboss" "lobwife" "lobsigliere")
SCALED_DOWN=()
if kubectl --context "$KUBE_CONTEXT" get ns lobmob &>/dev/null; then
  for dep in "${DEPLOYMENTS[@]}"; do
    replicas=$(kubectl --context "$KUBE_CONTEXT" -n lobmob get deploy "$dep" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    if [[ "$replicas" -gt 0 ]]; then
      SCALED_DOWN+=("$dep")
    fi
  done
  if [[ ${#SCALED_DOWN[@]} -gt 0 ]]; then
    log "Scaling down ${SCALED_DOWN[*]} before terraform apply..."
    kubectl --context "$KUBE_CONTEXT" -n lobmob scale deploy "${SCALED_DOWN[@]}" --replicas=0
  fi
fi

terraform apply tfplan

# --- Wait for nodes ---

log "Waiting for all nodes to be Ready..."
for i in $(seq 1 60); do
  NOT_READY=$(kubectl --context "$KUBE_CONTEXT" get nodes --no-headers 2>/dev/null \
    | grep -cv ' Ready' || true)
  if [[ "$NOT_READY" -eq 0 ]]; then
    NODES=$(kubectl --context "$KUBE_CONTEXT" get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$NODES" -gt 0 ]]; then
      log "All $NODES nodes Ready"
      break
    fi
  fi
  if [[ "$i" -eq 60 ]]; then
    warn "Timed out waiting for nodes (5min). Continuing anyway..."
  fi
  sleep 5
done

# --- K8s manifests ---

log "Applying k8s manifests (overlay=$OVERLAY)..."
kubectl --context "$KUBE_CONTEXT" apply -k "$PROJECT_DIR/k8s/overlays/$OVERLAY/"

log "Syncing k8s secrets..."
push_k8s_secrets

# --- Scale back up ---

if [[ ${#SCALED_DOWN[@]} -gt 0 ]]; then
  log "Scaling up ${SCALED_DOWN[*]}..."
  kubectl --context "$KUBE_CONTEXT" -n lobmob scale deploy "${SCALED_DOWN[@]}" --replicas=1
fi

# --- Verify pods ---

log "Waiting for pods to be Ready..."
for dep in "${DEPLOYMENTS[@]}"; do
  kubectl --context "$KUBE_CONTEXT" -n lobmob rollout status deploy/"$dep" --timeout=120s 2>/dev/null || \
    warn "$dep did not become Ready within 120s"
done

log ""
log "Deployed. Check status with: lobmob status"
