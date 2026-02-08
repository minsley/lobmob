#!/bin/bash
set -euo pipefail
source /etc/lobmob/env

LOBSTER_NAME="$1"

# Look up droplet ID
DROPLET_ID=$(doctl compute droplet list \
  --tag-name "$LOBSTER_TAG" \
  --format ID,Name \
  --no-header | grep "$LOBSTER_NAME" | awk '{print $1}')

if [ -z "$DROPLET_ID" ]; then
  echo "Lobster $LOBSTER_NAME not found"
  exit 1
fi

echo "Sleeping $LOBSTER_NAME (droplet $DROPLET_ID)..."

# Flush lobster's event log before sleep
# Find WG IP by checking peers
WG_IP=$(wg show wg0 allowed-ips 2>/dev/null | while read -r PK ALLOWED; do
  IP=$(echo "$ALLOWED" | cut -d/ -f1)
  REMOTE_ID=$(ssh -i /root/.ssh/lobster_admin -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new \
    "root@$IP" "cat /etc/lobmob/env 2>/dev/null | grep LOBSTER_ID | cut -d= -f2" 2>/dev/null || true)
  if echo "$LOBSTER_NAME" | grep -q "$REMOTE_ID" 2>/dev/null && [ -n "$REMOTE_ID" ]; then
    echo "$IP"; break
  fi
done)
if [ -n "$WG_IP" ]; then
  ssh -i /root/.ssh/lobster_admin -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
    "root@$WG_IP" "lobmob-flush-logs" 2>/dev/null || true
fi

# Graceful shutdown with timeout
doctl compute droplet-action shutdown "$DROPLET_ID" --wait 2>/dev/null &
SHUTDOWN_PID=$!
TIMEOUT=120
ELAPSED=0
while kill -0 "$SHUTDOWN_PID" 2>/dev/null; do
  sleep 5
  ELAPSED=$((ELAPSED + 5))
  if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    kill "$SHUTDOWN_PID" 2>/dev/null || true
    echo "Graceful shutdown timed out, forcing power-off..."
    doctl compute droplet-action power-off "$DROPLET_ID" --wait
    break
  fi
done
wait "$SHUTDOWN_PID" 2>/dev/null || true

lobmob-log sleep "$LOBSTER_NAME droplet=$DROPLET_ID"
echo "Lobster $LOBSTER_NAME is now standby (powered off)"
