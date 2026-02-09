load_secrets

LOBBOSS_ID=$(get_lobboss_id)
if [ -z "$LOBBOSS_ID" ]; then
  err "Lobboss droplet not found. Is it deployed?"
  exit 1
fi

# Check if already off
STATUS=$(doctl compute droplet get "$LOBBOSS_ID" \
  --format Status --no-header --access-token "$DO_TOKEN" 2>/dev/null)
if [ "$STATUS" = "off" ]; then
  warn "Lobboss is already asleep"
  return
fi

# Cull all lobsters first
log "Culling all lobsters before sleep..."
LOBBOSS_IP=$(get_lobboss_ip)
if [ -n "$LOBBOSS_IP" ]; then
  lobmob_ssh -o ConnectTimeout=10 "root@$LOBBOSS_IP" \
    'source /etc/lobmob/env && doctl compute droplet delete-by-tag "$LOBSTER_TAG" --force' 2>/dev/null || true
fi
# Belt-and-suspenders: also cull via API in case SSH missed any
local PROJECT_NAME
PROJECT_NAME=$(grep project_name "$INFRA_DIR/terraform.tfvars" 2>/dev/null | cut -d'"' -f2)
PROJECT_NAME="${PROJECT_NAME:-lobmob}"
curl -s -X DELETE \
  "https://api.digitalocean.com/v2/droplets?tag_name=${PROJECT_NAME}-lobster" \
  -H "Authorization: Bearer $DO_TOKEN" > /dev/null 2>&1 || true
log "Lobsters culled"

# Graceful shutdown
log "Shutting down lobboss..."
doctl compute droplet-action shutdown "$LOBBOSS_ID" \
  --access-token "$DO_TOKEN" --wait 2>/dev/null || true

# Verify it's off — fall back to hard power-off if graceful shutdown stalled
sleep 5
STATUS=$(doctl compute droplet get "$LOBBOSS_ID" \
  --format Status --no-header --access-token "$DO_TOKEN" 2>/dev/null)
if [ "$STATUS" != "off" ]; then
  warn "Graceful shutdown incomplete, forcing power off..."
  doctl compute droplet-action power-off "$LOBBOSS_ID" \
    --access-token "$DO_TOKEN" --wait
fi

log "Lobboss is asleep. Run 'lobmob wake' to resume."
