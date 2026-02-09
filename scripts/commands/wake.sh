load_secrets

LOBBOSS_ID=$(get_lobboss_id)
if [ -z "$LOBBOSS_ID" ]; then
  err "Lobboss droplet not found. Is it deployed?"
  exit 1
fi

# Check if already running
STATUS=$(doctl compute droplet get "$LOBBOSS_ID" \
  --format Status --no-header --access-token "$DO_TOKEN" 2>/dev/null)
if [ "$STATUS" = "active" ]; then
  warn "Lobboss is already awake"
  return
fi

log "Powering on lobboss..."
doctl compute droplet-action power-on "$LOBBOSS_ID" \
  --access-token "$DO_TOKEN" --wait

LOBBOSS_IP=$(get_lobboss_ip)
wait_for_ssh "$LOBBOSS_IP"

# Restart WireGuard (may not auto-start after power cycle)
lobmob_ssh "root@$LOBBOSS_IP" "systemctl restart wg-quick@wg0" 2>/dev/null || true

log "Lobboss is awake at $LOBBOSS_IP"
log "  SSH:    lobmob ssh-lobboss"
log "  Spawn:  lobmob spawn"
