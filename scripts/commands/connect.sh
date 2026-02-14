# lobmob connect — port-forward to lobboss or a lobster pod and open browser
# Usage:
#   lobmob connect                       -> lobboss dashboard
#   lobmob connect lobster-swe-task-123  -> specific lobster pod

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
  log "Port-forwarding to lobboss service ($LOBMOB_ENV)..."
  log "Dashboard: http://localhost:$LOCAL_PORT"
  log "Press Ctrl+C to disconnect"
  echo ""

  # Open browser after a short delay
  ( sleep 2 && open_browser "http://localhost:$LOCAL_PORT" ) &

  kubectl --context "$KUBE_CONTEXT" -n lobmob port-forward svc/lobboss "$LOCAL_PORT:8080"

elif [[ "$TARGET" == "lobsigliere" ]]; then
  SSH_PORT="${LOBMOB_SSH_PORT:-2222}"
  log "Connecting to lobsigliere ($LOBMOB_ENV)..."

  # Port-forward in background, SSH when ready, clean up on exit
  kubectl --context "$KUBE_CONTEXT" -n lobmob port-forward svc/lobsigliere "$SSH_PORT:22" &>/dev/null &
  PF_PID=$!
  trap "kill $PF_PID 2>/dev/null" EXIT

  # Wait for port-forward to be ready
  for i in $(seq 1 20); do
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=1 -p "$SSH_PORT" engineer@localhost true 2>/dev/null; then
      break
    fi
    sleep 0.5
  done

  ssh -o StrictHostKeyChecking=no -p "$SSH_PORT" engineer@localhost

elif [[ "$TARGET" == "lobwife" ]]; then
  log "Port-forwarding to lobwife service ($LOBMOB_ENV)..."
  log "Dashboard: http://localhost:$LOCAL_PORT"
  log "Press Ctrl+C to disconnect"
  echo ""

  ( sleep 2 && open_browser "http://localhost:$LOCAL_PORT" ) &

  kubectl --context "$KUBE_CONTEXT" -n lobmob port-forward svc/lobwife "$LOCAL_PORT:8080"

elif [[ "$TARGET" == "lobwife-ssh" ]]; then
  SSH_PORT="${LOBMOB_SSH_PORT:-2223}"
  log "Connecting to lobwife via SSH ($LOBMOB_ENV)..."

  kubectl --context "$KUBE_CONTEXT" -n lobmob port-forward svc/lobwife "$SSH_PORT:22" &>/dev/null &
  PF_PID=$!
  trap "kill $PF_PID 2>/dev/null" EXIT

  for i in $(seq 1 20); do
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=1 -p "$SSH_PORT" lobwife@localhost true 2>/dev/null; then
      break
    fi
    sleep 0.5
  done

  ssh -o StrictHostKeyChecking=no -p "$SSH_PORT" lobwife@localhost
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
    log "Active lobster pods:"
    kubectl --context "$KUBE_CONTEXT" -n lobmob get pods -l "app.kubernetes.io/name=lobster" --no-headers 2>/dev/null || true
    exit 1
  fi

  log "Port-forwarding to pod $POD_NAME ($LOBMOB_ENV)..."
  log "Dashboard: http://localhost:$LOCAL_PORT"
  log "Press Ctrl+C to disconnect"
  echo ""

  ( sleep 2 && open_browser "http://localhost:$LOCAL_PORT" ) &

  # Forward to the web sidecar container's port
  kubectl --context "$KUBE_CONTEXT" -n lobmob port-forward "pod/$POD_NAME" "$LOCAL_PORT:8080"
fi
