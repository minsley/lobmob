# lobmob cluster-create — create a local k3d cluster for local development
# Usage:
#   lobmob --env local cluster-create
#
# Creates a 5-node k3d cluster (1 server + 4 agents) with node labels matching
# the DOKS node pool architecture. Base manifests apply unchanged.

if [[ "$LOBMOB_ENV" != "local" ]]; then
  err "cluster-create requires --env local"
  exit 1
fi

CLUSTER_NAME="lobmob-local"
KUBE_CONTEXT="k3d-${CLUSTER_NAME}"

# Check k3d is installed
if ! command -v k3d &>/dev/null; then
  err "k3d not found. Install with: brew install k3d"
  exit 1
fi

# Check if cluster already exists
if k3d cluster list 2>/dev/null | grep -q "^${CLUSTER_NAME}"; then
  warn "Cluster '${CLUSTER_NAME}' already exists"
  log "Use 'lobmob --env local cluster-delete' to remove it first"
  log "Or use 'lobmob --env local apply' to deploy to the existing cluster"
  exit 0
fi

log "Creating k3d cluster '${CLUSTER_NAME}' (5 nodes)..."

# Create cluster: 1 server + 4 agents
# --no-lb: skip load balancer (not needed for local dev)
k3d cluster create "${CLUSTER_NAME}" \
  --agents 4 \
  --no-lb \
  --k3s-arg "--disable=traefik@server:0"

log "Labeling nodes with lobmob.io/role..."

# Label nodes to match DOKS node pool architecture
# server-0 gets lobsigliere role (control plane + default pool)
# agents get dedicated roles matching the cloud pools
k3d node list --cluster "${CLUSTER_NAME}" -o json 2>/dev/null | \
  python3 -c "
import json, sys
nodes = json.load(sys.stdin)
# Filter to only k3s nodes (not registry/load balancer nodes)
k3s_nodes = [n for n in nodes if n.get('role') in ('server', 'agent')]
# Sort: servers first, then agents
servers = [n for n in k3s_nodes if n['role'] == 'server']
agents  = [n for n in k3s_nodes if n['role'] == 'agent']
ordered = servers + agents
roles = ['lobsigliere', 'lobwife', 'lobboss', 'lobsters', 'lobsters']
for i, node in enumerate(ordered):
  role = roles[i] if i < len(roles) else 'lobsters'
  # k3d node names use format k3d-<cluster>-<role>-<n>
  # but in kubectl they appear as just the container name
  print(node['name'] + '=' + role)
" | while IFS='=' read -r node_name role; do
  # Strip k3d- prefix for kubectl
  kube_node="${node_name#k3d-}"
  kubectl --context "${KUBE_CONTEXT}" label node "${kube_node}" \
    "lobmob.io/role=${role}" --overwrite 2>/dev/null || \
  kubectl --context "${KUBE_CONTEXT}" label node "${node_name}" \
    "lobmob.io/role=${role}" --overwrite 2>/dev/null || true
done

log "Cluster created: ${KUBE_CONTEXT}"
log ""
log "Node layout:"
kubectl --context "${KUBE_CONTEXT}" get nodes -L lobmob.io/role 2>/dev/null || true
log ""
log "Next steps:"
log "  1. Fill in secrets-local.env (copy from secrets-dev.env, update TASK_QUEUE_CHANNEL_ID)"
log "  2. Build images:  lobmob --env local build all"
log "  3. Deploy:        lobmob --env local deploy"
