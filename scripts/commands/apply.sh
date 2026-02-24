# lobmob apply — apply k8s manifests without terraform
# Usage:
#   lobmob apply               -> apply manifests for current env
#   lobmob apply --dry-run     -> validate only

if [[ "$LOBMOB_ENV" == "dev" ]]; then
  KUBE_CONTEXT="do-nyc3-lobmob-dev-k8s"
  OVERLAY="dev"
elif [[ "$LOBMOB_ENV" == "local" ]]; then
  KUBE_CONTEXT="k3d-lobmob-local"
  OVERLAY="local"
else
  KUBE_CONTEXT="do-nyc3-lobmob-k8s"
  OVERLAY="prod"
fi

EXTRA_ARGS=()
if [[ "${1:-}" == "--dry-run" ]]; then
  EXTRA_ARGS+=(--dry-run=client)
  log "Dry run — validating manifests ($LOBMOB_ENV)..."
else
  log "Applying k8s manifests ($LOBMOB_ENV, overlay=$OVERLAY)..."
fi

kubectl --context "$KUBE_CONTEXT" apply -k "$PROJECT_DIR/k8s/overlays/$OVERLAY/" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}

if [[ "${1:-}" != "--dry-run" ]]; then
  log "Syncing k8s secrets..."
  load_secrets
  push_k8s_secrets
  log "Applied. Check status with: lobmob status"
fi
