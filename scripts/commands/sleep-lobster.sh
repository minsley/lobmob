if [ -z "${1:-}" ]; then
  err "Usage: lobmob sleep-lobster <lobster-name>"
  exit 1
fi
LOBBOSS_IP=$(get_lobboss_ip)
if [ -z "$LOBBOSS_IP" ]; then
  err "Lobboss not deployed. Run: lobmob deploy"
  exit 1
fi
log "Sleeping $1 via lobboss..."
lobmob_ssh "root@$LOBBOSS_IP" "lobmob-sleep-lobster $1"
