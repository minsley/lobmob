#!/bin/bash
set -euo pipefail
source /etc/lobmob/env
source /etc/lobmob/secrets.env

SNAPSHOT_NAME="lobboss-$(date +%Y%m%d-%H%M)"
MAX_SNAPSHOTS=4

# Get lobboss droplet ID from DO metadata
DROPLET_ID=$(curl -s http://169.254.169.254/metadata/v1/id)
if [ -z "$DROPLET_ID" ]; then
  echo "ERROR: Could not get droplet ID from metadata"
  exit 1
fi

echo "Creating snapshot: $SNAPSHOT_NAME for droplet $DROPLET_ID"
doctl compute droplet-action snapshot "$DROPLET_ID" \
  --snapshot-name "$SNAPSHOT_NAME" --wait 2>&1

echo "Snapshot created: $SNAPSHOT_NAME"
lobmob-log snapshot "$SNAPSHOT_NAME droplet=$DROPLET_ID"

# Prune old snapshots (keep only MAX_SNAPSHOTS most recent)
SNAPSHOTS=$(doctl compute snapshot list \
  --resource droplet \
  --format ID,Name,CreatedAt \
  --no-header 2>/dev/null \
  | grep "lobboss-" \
  | sort -k3 -r)

COUNT=0
echo "$SNAPSHOTS" | while read -r snap_id snap_name snap_date rest; do
  COUNT=$((COUNT + 1))
  if [ $COUNT -gt $MAX_SNAPSHOTS ]; then
    echo "Pruning old snapshot: $snap_name ($snap_id)"
    doctl compute snapshot delete "$snap_id" --force 2>/dev/null || true
  fi
done
