LOBBOSS_IP=$(get_lobboss_ip)
if [ -z "$LOBBOSS_IP" ]; then
  err "Lobboss not deployed"
  exit 1
fi
lobmob_ssh "root@$LOBBOSS_IP" "lobmob-fleet-status"
