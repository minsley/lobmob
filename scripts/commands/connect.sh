# lobmob connect — port-forward to lobboss or a lobster pod and open browser
# Usage:
#   lobmob connect                       -> lobboss dashboard
#   lobmob connect lobster-swe-task-123  -> specific lobster pod

set -euo pipefail

LOCAL_PORT="${LOBMOB_CONNECT_PORT:-8080}"
TARGET="${1:-lobboss}"

# Determine kubectl context
if [[ "$LOBMOB_ENV" == "dev" ]]; then
  KUBE_CONTEXT="do-nyc3-lobmob-dev-k8s"
else
  KUBE_CONTEXT="do-nyc3-lobmob-k8s"
fi

open_browser() {
  local url="$1"
  case "${OSTYPE:-}" in
    darwin*) open "$url" ;;
    linux*)  xdg-open "$url" 2>/dev/null || echo "Open: $url" ;;
    *)       echo "Open: $url" ;;
  esac
}

if [[ "$TARGET" == "lobboss" ]]; then
  info "Port-forwarding to lobboss service ($LOBMOB_ENV)..."
  info "Dashboard: http://localhost:$LOCAL_PORT"
  info "Press Ctrl+C to disconnect"
  echo ""

  # Open browser after a short delay
  ( sleep 2 && open_browser "http://localhost:$LOCAL_PORT" ) &

  kubectl --context "$KUBE_CONTEXT" -n lobmob port-forward svc/lobboss "$LOCAL_PORT:8080"
else
  # Find the pod for a lobster job
  POD_NAME=$(kubectl --context "$KUBE_CONTEXT" -n lobmob get pods \
    -l "job-name=$TARGET" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [[ -z "$POD_NAME" ]]; then
    # Try matching as a partial name
    POD_NAME=$(kubectl --context "$KUBE_CONTEXT" -n lobmob get pods \
      -l "app.kubernetes.io/name=lobster" \
      -o jsonpath="{.items[?(@.metadata.name=~'$TARGET')].metadata.name}" 2>/dev/null | awk '{print $1}' || true)
  fi

  if [[ -z "$POD_NAME" ]]; then
    err "No running pod found for: $TARGET"
    info "Active lobster pods:"
    kubectl --context "$KUBE_CONTEXT" -n lobmob get pods -l "app.kubernetes.io/name=lobster" --no-headers 2>/dev/null || true
    exit 1
  fi

  info "Port-forwarding to pod $POD_NAME ($LOBMOB_ENV)..."
  info "Dashboard: http://localhost:$LOCAL_PORT"
  info "Press Ctrl+C to disconnect"
  echo ""

  ( sleep 2 && open_browser "http://localhost:$LOCAL_PORT" ) &

  # Forward to the web sidecar container's port
  kubectl --context "$KUBE_CONTEXT" -n lobmob port-forward "pod/$POD_NAME" "$LOCAL_PORT:8080"
fi
