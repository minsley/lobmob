load_secrets 2>/dev/null || true

# Use the DO API to bulk-delete all lobsters by tag
PROJECT_NAME=$(grep project_name "$TFVARS_FILE" 2>/dev/null | cut -d'"' -f2)
PROJECT_NAME="${PROJECT_NAME:-lobmob}"
TAG="${PROJECT_NAME}-lobster"

log "Destroying all lobsters (tag: $TAG)..."

# Delete via DO API (doctl doesn't have a delete-by-tag command)
DROPLET_IDS=$(curl -s "https://api.digitalocean.com/v2/droplets?tag_name=$TAG&per_page=100" \
  -H "Authorization: Bearer $DO_TOKEN" 2>/dev/null | jq -r '.droplets[].id' 2>/dev/null)

if [ -z "$DROPLET_IDS" ]; then
  log "No lobsters found"
  exit 0
fi

for id in $DROPLET_IDS; do
  NAME=$(curl -s "https://api.digitalocean.com/v2/droplets/$id" \
    -H "Authorization: Bearer $DO_TOKEN" 2>/dev/null | jq -r '.droplet.name')
  curl -s -X DELETE "https://api.digitalocean.com/v2/droplets/$id" \
    -H "Authorization: Bearer $DO_TOKEN" 2>/dev/null
  log "  Destroyed $NAME ($id)"
done

log "All lobsters destroyed"
