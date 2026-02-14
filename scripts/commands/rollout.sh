# lobmob rollout — build, push, restart, and verify a service
# Usage:
#   lobmob rollout lobwife         -> build + restart + verify
#   lobmob rollout lobboss         -> build + restart + verify
#   lobmob rollout lobsigliere     -> build + restart + verify
#   lobmob rollout lobster         -> build only (lobsters are ephemeral jobs)

if [[ "$LOBMOB_ENV" == "dev" ]]; then
  KUBE_CONTEXT="do-nyc3-lobmob-dev-k8s"
else
  KUBE_CONTEXT="do-nyc3-lobmob-k8s"
fi

TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
  err "Usage: lobmob rollout <lobwife|lobboss|lobsigliere|lobster>"
  exit 1
fi

case "$TARGET" in
  lobwife|lobboss|lobsigliere)
    # Build and push
    source "$SCRIPT_DIR/commands/build.sh"

    # Restart deployment
    log "Restarting $TARGET ($LOBMOB_ENV)..."
    kubectl --context "$KUBE_CONTEXT" -n lobmob rollout restart "deployment/$TARGET"
    kubectl --context "$KUBE_CONTEXT" -n lobmob rollout status "deployment/$TARGET" --timeout=180s

    # Verify
    log "Running verification..."
    source "$SCRIPT_DIR/commands/verify.sh"
    ;;
  lobster)
    # Lobsters are ephemeral — just build
    source "$SCRIPT_DIR/commands/build.sh"
    log "Lobster image pushed. New jobs will use the updated image."
    ;;
  *)
    err "Unknown target: $TARGET"
    err "Valid targets: lobwife, lobboss, lobsigliere, lobster"
    exit 1
    ;;
esac
