# lobmob cluster-delete — delete the local k3d cluster
# Usage:
#   lobmob --env local cluster-delete

if [[ "$LOBMOB_ENV" != "local" ]]; then
  err "cluster-delete requires --env local"
  exit 1
fi

CLUSTER_NAME="lobmob-local"

if ! command -v k3d &>/dev/null; then
  err "k3d not found. Install with: brew install k3d"
  exit 1
fi

if ! k3d cluster list 2>/dev/null | grep -q "^${CLUSTER_NAME}"; then
  warn "Cluster '${CLUSTER_NAME}' not found — nothing to delete"
  exit 0
fi

log "Deleting k3d cluster '${CLUSTER_NAME}'..."
k3d cluster delete "${CLUSTER_NAME}"
log "Cluster deleted"
