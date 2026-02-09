if [ -z "${1:-}" ]; then
  err "Usage: lobmob teardown <lobster-name>"
  exit 1
fi
LOBBOSS_IP=$(get_lobboss_ip)
log "Tearing down $1 via lobboss..."
lobmob_ssh "root@$LOBBOSS_IP" "lobmob-teardown-lobster $1"
