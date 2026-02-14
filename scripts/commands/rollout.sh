# lobmob rollout — build, push, restart, and verify a service
# Usage:
#   lobmob rollout lobwife         -> build + restart + verify
#   lobmob rollout lobboss         -> build + restart + verify
#   lobmob rollout lobsigliere     -> build + restart + verify
#   lobmob rollout lobster         -> build only (lobsters are ephemeral jobs)

TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
  err "Usage: lobmob rollout <lobwife|lobboss|lobsigliere|lobster>"
  exit 1
fi

case "$TARGET" in
  lobwife|lobboss|lobsigliere)
    source "$SCRIPT_DIR/commands/build.sh"
    source "$SCRIPT_DIR/commands/restart.sh"
    log "Running verification..."
    source "$SCRIPT_DIR/commands/verify.sh"
    ;;
  lobster)
    source "$SCRIPT_DIR/commands/build.sh"
    log "Lobster image pushed. New jobs will use the updated image."
    ;;
  *)
    err "Unknown target: $TARGET"
    err "Valid targets: lobwife, lobboss, lobsigliere, lobster"
    exit 1
    ;;
esac
