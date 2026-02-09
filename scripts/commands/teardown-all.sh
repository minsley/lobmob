LOBBOSS_IP=$(get_lobboss_ip)
if [ -z "$LOBBOSS_IP" ]; then
  warn "Lobboss not reachable — attempting direct API teardown"
  load_secrets 2>/dev/null || true
  if [ -n "${DO_TOKEN:-}" ]; then
    curl -s -X DELETE "https://api.digitalocean.com/v2/droplets?tag_name=lobmob-lobster" \
      -H "Authorization: Bearer $DO_TOKEN"
    log "Sent bulk delete for all lobmob-lobster tagged droplets"
  else
    err "No DO token available"
  fi
  return
fi

log "Destroying all lobsters via lobboss..."
lobmob_ssh "root@$LOBBOSS_IP" 'source /etc/lobmob/env && doctl compute droplet delete-by-tag "$LOBSTER_TAG" --force' || true
log "All lobsters destroyed"
