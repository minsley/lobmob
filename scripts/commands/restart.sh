# lobmob restart — rollout restart a deployment and wait for it
# Usage:
#   lobmob restart lobwife
#   lobmob restart lobboss
#   lobmob restart lobsigliere
#   lobmob restart all

if [[ "$LOBMOB_ENV" == "dev" ]]; then
  KUBE_CONTEXT="do-nyc3-lobmob-dev-k8s"
elif [[ "$LOBMOB_ENV" == "local" ]]; then
  KUBE_CONTEXT="k3d-lobmob-local"
else
  KUBE_CONTEXT="do-nyc3-lobmob-k8s"
fi

TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
  err "Usage: lobmob restart <lobwife|lobboss|lobsigliere|all>"
  exit 1
fi

restart_deployment() {
  local name="$1"
  log "Restarting $name ($LOBMOB_ENV)..."
  kubectl --context "$KUBE_CONTEXT" -n lobmob rollout restart "deployment/$name"
  kubectl --context "$KUBE_CONTEXT" -n lobmob rollout status "deployment/$name" --timeout=180s
  log "$name restarted successfully"
}

case "$TARGET" in
  lobwife|lobboss|lobsigliere)
    restart_deployment "$TARGET"
    ;;
  all)
    restart_deployment lobboss
    restart_deployment lobwife
    restart_deployment lobsigliere
    ;;
  *)
    err "Unknown target: $TARGET"
    err "Valid targets: lobwife, lobboss, lobsigliere, all"
    exit 1
    ;;
esac
