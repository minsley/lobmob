LOBBOSS_IP=$(get_lobboss_ip)
lobmob_ssh "root@$LOBBOSS_IP" "tail -100f /var/log/cloud-init-output.log"
