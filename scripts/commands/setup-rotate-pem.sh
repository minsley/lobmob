# lobmob setup rotate-pem — emergency PEM key rotation
# Usage:
#   lobmob setup rotate-pem <pem-file>
#   lobmob setup rotate-pem --from-stdin < new-key.pem

if [[ "$LOBMOB_ENV" == "dev" ]]; then
  KUBE_CONTEXT="do-nyc3-lobmob-dev-k8s"
else
  KUBE_CONTEXT="do-nyc3-lobmob-k8s"
fi

PEM_SOURCE="${1:-}"

# Read PEM from file or stdin
if [[ "$PEM_SOURCE" == "--from-stdin" ]]; then
  PEM_RAW=$(cat)
elif [[ -n "$PEM_SOURCE" && -f "$PEM_SOURCE" ]]; then
  PEM_RAW=$(cat "$PEM_SOURCE")
else
  err "Usage: lobmob setup rotate-pem <pem-file>"
  err "       lobmob setup rotate-pem --from-stdin < key.pem"
  exit 1
fi

# Validate PEM format
if [[ "$PEM_RAW" != *"BEGIN RSA PRIVATE KEY"* && "$PEM_RAW" != *"BEGIN PRIVATE KEY"* ]]; then
  err "File does not appear to be a PEM private key"
  exit 1
fi

PEM_B64=$(echo "$PEM_RAW" | base64)

# Load existing secrets (need GH_APP_ID and GH_APP_INSTALL_ID)
if [[ ! -f "$SECRETS_FILE" ]]; then
  err "Secrets file not found: $SECRETS_FILE"
  exit 1
fi
load_secrets

if [[ -z "${GH_APP_ID:-}" || -z "${GH_APP_INSTALL_ID:-}" ]]; then
  err "GH_APP_ID and GH_APP_INSTALL_ID must be set in $SECRETS_FILE"
  exit 1
fi

# 1. Update secrets file
log "Updating $SECRETS_FILE..."
if grep -q "^GH_APP_PEM=" "$SECRETS_FILE"; then
  portable_sed_i "s|^GH_APP_PEM=.*|GH_APP_PEM=${PEM_B64}|" "$SECRETS_FILE"
else
  echo "GH_APP_PEM=${PEM_B64}" >> "$SECRETS_FILE"
fi

# 2. Update k8s secret
log "Updating lobwife-secrets in k8s ($LOBMOB_ENV)..."
kubectl --context "$KUBE_CONTEXT" -n lobmob create secret generic lobwife-secrets \
  --from-literal="GH_APP_PEM=${PEM_B64}" \
  --from-literal="GH_APP_ID=${GH_APP_ID}" \
  --from-literal="GH_APP_INSTALL_ID=${GH_APP_INSTALL_ID}" \
  --dry-run=client -o yaml | kubectl --context "$KUBE_CONTEXT" apply -f -

# 3. Restart lobwife
log "Restarting lobwife..."
kubectl --context "$KUBE_CONTEXT" -n lobmob rollout restart deployment/lobwife
kubectl --context "$KUBE_CONTEXT" -n lobmob rollout status deployment/lobwife --timeout=120s

# 4. Verify health
log "Verifying broker health..."
sleep 5
kubectl --context "$KUBE_CONTEXT" -n lobmob port-forward svc/lobwife 18080:8080 &>/dev/null &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null; wait "$PF_PID" 2>/dev/null || true' EXIT
sleep 3

HEALTH=$(curl -sf http://localhost:18080/health 2>/dev/null || true)
kill "$PF_PID" 2>/dev/null; wait "$PF_PID" 2>/dev/null || true
trap - EXIT

if [[ "$HEALTH" == *'"ok"'* ]]; then
  log "PEM rotation complete. Lobwife is healthy."
  log "Note: existing installation tokens remain valid up to 1 hour."
else
  err "Lobwife health check failed after rotation. Check pod logs:"
  err "  lobmob logs lobwife"
  exit 1
fi
