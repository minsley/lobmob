#!/bin/bash
source /etc/lobmob/env

POOL_ACTIVE="${POOL_ACTIVE:-1}"
POOL_STANDBY="${POOL_STANDBY:-2}"
CONFIG_VERSION=$(md5sum /usr/local/bin/lobmob-spawn-lobster 2>/dev/null | awk '{print $1}')

echo "=== Pool Config ==="
echo "  POOL_ACTIVE=$POOL_ACTIVE  POOL_STANDBY=$POOL_STANDBY"
echo "  Config version: ${CONFIG_VERSION:0:8}..."
echo ""

echo "=== Lobster Droplets ==="
DROPLETS=$(doctl compute droplet list --tag-name "$LOBSTER_TAG" --format ID,Name,PublicIPv4,Status,Created --no-header 2>/dev/null)
if [ -z "$DROPLETS" ]; then
  echo "  (none)"
else
  echo "$DROPLETS"
fi

# Classify by state
BUSY=0
IDLE=0
STANDBY_COUNT=0
while read -r ID NAME _ STATUS _; do
  [ -z "$ID" ] && continue
  if [ "$STATUS" = "off" ]; then
    STANDBY_COUNT=$((STANDBY_COUNT + 1))
  elif [ "$STATUS" = "active" ]; then
    LOBSTER_SHORT=$(echo "$NAME" | sed 's/^lobster-//')
    if grep -rl "$LOBSTER_SHORT" /opt/vault/010-tasks/active/ 2>/dev/null | head -1 | grep -q .; then
BUSY=$((BUSY + 1))
    else
IDLE=$((IDLE + 1))
    fi
  fi
done <<< "$DROPLETS"

echo ""
echo "=== Pool State ==="
echo "  active-busy: $BUSY"
echo "  active-idle: $IDLE (target: $POOL_ACTIVE)"
echo "  standby:     $STANDBY_COUNT (target: $POOL_STANDBY)"
echo ""

echo "=== WireGuard Peers ==="
wg show wg0

echo ""
echo "=== Open PRs ==="
cd /opt/vault && gh pr list --state open --json number,title,headRefName,author,createdAt 2>/dev/null || echo "No vault repo"
