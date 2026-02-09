LOBBOSS_IP=$(get_lobboss_ip)
log "Connecting to lobboss at $LOBBOSS_IP..."
lobmob_ssh "root@$LOBBOSS_IP"
