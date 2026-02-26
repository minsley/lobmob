# lobmob status — show fleet status from k8s

if [[ "$LOBMOB_ENV" == "dev" ]]; then
  KUBE_CONTEXT="do-nyc3-lobmob-dev-k8s"
elif [[ "$LOBMOB_ENV" == "local" ]]; then
  KUBE_CONTEXT="k3d-lobmob-local"
else
  KUBE_CONTEXT="do-nyc3-lobmob-k8s"
fi

log "Fleet status ($LOBMOB_ENV)"
echo ""

# lobboss
log "Lobboss:"
kubectl --context "$KUBE_CONTEXT" -n lobmob get pods -l app.kubernetes.io/name=lobboss --no-headers 2>/dev/null || echo "  (not found)"
echo ""

# lobwife
log "Lobwife:"
kubectl --context "$KUBE_CONTEXT" -n lobmob get pods -l app.kubernetes.io/name=lobwife --no-headers 2>/dev/null || echo "  (not found)"
echo ""

# lobsigliere
log "Lobsigliere:"
kubectl --context "$KUBE_CONTEXT" -n lobmob get pods -l app.kubernetes.io/name=lobsigliere --no-headers 2>/dev/null || echo "  (not found)"
echo ""

# lobster jobs
log "Lobster jobs:"
kubectl --context "$KUBE_CONTEXT" -n lobmob get jobs -l app.kubernetes.io/name=lobster --no-headers 2>/dev/null || echo "  (none)"
echo ""

# lobster pods
log "Lobster pods:"
kubectl --context "$KUBE_CONTEXT" -n lobmob get pods -l app.kubernetes.io/name=lobster --no-headers 2>/dev/null || echo "  (none)"
echo ""

# open PRs
log "Open PRs:"
gh pr list --state open --limit 10 2>/dev/null || echo "  (unable to list)"
