#!/bin/bash
set -euo pipefail
source /etc/lobmob/env
source /etc/lobmob/secrets.env

LOBSTER_NAME="$1"

# Get droplet ID and public IP
DROPLET_INFO=$(doctl compute droplet list \
  --tag-name "$LOBSTER_TAG" \
  --format ID,Name,PublicIPv4 \
  --no-header | grep "$LOBSTER_NAME")

DROPLET_ID=$(echo "$DROPLET_INFO" | awk '{print $1}')
DROPLET_IP=$(echo "$DROPLET_INFO" | awk '{print $3}')

if [ -z "$DROPLET_ID" ]; then
  echo "Lobster $LOBSTER_NAME not found"
  exit 1
fi

# Best-effort: flush lobster's event log before destroy
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

# Remove WireGuard peer by matching endpoint IP
WG_PUBKEY=""
if [ -n "$DROPLET_IP" ]; then
  WG_PUBKEY=$(wg show wg0 endpoints 2>/dev/null \
    | grep "$DROPLET_IP:" | awk '{print $1}' || true)
fi
# Fallback: check vault registry
if [ -z "$WG_PUBKEY" ]; then
  WG_PUBKEY=$(grep "$LOBSTER_NAME" /opt/vault/040-fleet/registry.md 2>/dev/null \
    | grep -oP 'wg_pubkey: \K\S+' || true)
fi
if [ -n "$WG_PUBKEY" ]; then
  wg set wg0 peer "$WG_PUBKEY" remove
  echo "Removed WireGuard peer $WG_PUBKEY"
fi

# Destroy droplet
doctl compute droplet delete "$DROPLET_ID" --force

lobmob-log destroy "$LOBSTER_NAME droplet=$DROPLET_ID"
echo "Destroyed $LOBSTER_NAME (droplet $DROPLET_ID)"
