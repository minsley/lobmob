HOURS="${1:-2}"
LOBBOSS_IP=$(get_lobboss_ip)
lobmob_ssh "root@$LOBBOSS_IP" "lobmob-cleanup $HOURS"
