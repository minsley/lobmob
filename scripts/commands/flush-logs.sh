LOBBOSS_IP=$(get_lobboss_ip)
if [ -z "$LOBBOSS_IP" ]; then
  err "Lobboss not deployed. Run: lobmob deploy"
  exit 1
fi
log "Flushing event logs on lobboss..."
lobmob_ssh "root@$LOBBOSS_IP" "lobmob-flush-logs"
log "Flush complete"
