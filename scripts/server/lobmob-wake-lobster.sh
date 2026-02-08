#!/bin/bash
set -euo pipefail
source /etc/lobmob/env
source /etc/lobmob/secrets.env

LOBSTER_NAME="$1"

# Look up droplet info
DROPLET_INFO=$(doctl compute droplet list \
  --tag-name "$LOBSTER_TAG" \
  --format ID,Name,Status \
  --no-header | grep "$LOBSTER_NAME")

if [ -z "$DROPLET_INFO" ]; then
  echo "Lobster $LOBSTER_NAME not found"
  exit 1
fi

DROPLET_ID=$(echo "$DROPLET_INFO" | awk '{print $1}')
DROPLET_STATUS=$(echo "$DROPLET_INFO" | awk '{print $3}')

if [ "$DROPLET_STATUS" = "active" ]; then
  echo "Lobster $LOBSTER_NAME is already active"
  exit 0
fi

echo "Waking $LOBSTER_NAME (droplet $DROPLET_ID)..."
doctl compute droplet-action power-on "$DROPLET_ID" --wait

# Look up WG IP from wg show (the peer config survives power cycle)
WG_IP=""
while read -r PUBKEY ALLOWED; do
  IP=$(echo "$ALLOWED" | cut -d/ -f1)
  # Try to match -- we'll ping all peers and see which comes alive
  if ping -c 1 -W 2 "$IP" > /dev/null 2>&1; then
    # Verify it's our lobster by SSHing in
    REMOTE_NAME=$(ssh -i /root/.ssh/lobster_admin -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
"root@$IP" "cat /etc/lobmob/env 2>/dev/null | grep LOBSTER_ID | cut -d= -f2" 2>/dev/null || true)
    if echo "$LOBSTER_NAME" | grep -q "$REMOTE_NAME" 2>/dev/null && [ -n "$REMOTE_NAME" ]; then
WG_IP="$IP"
break
    fi
  fi
done < <(wg show wg0 allowed-ips 2>/dev/null)

# If no WG IP found via matching, scan all peers for connectivity
if [ -z "$WG_IP" ]; then
  echo "Waiting for WireGuard connectivity..."
  for attempt in $(seq 1 30); do
    while read -r PUBKEY ALLOWED; do
IP=$(echo "$ALLOWED" | cut -d/ -f1)
if ping -c 1 -W 2 "$IP" > /dev/null 2>&1; then
  REMOTE_NAME=$(ssh -i /root/.ssh/lobster_admin -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
    "root@$IP" "cat /etc/lobmob/env 2>/dev/null | grep LOBSTER_ID | cut -d= -f2" 2>/dev/null || true)
  if echo "$LOBSTER_NAME" | grep -q "$REMOTE_NAME" 2>/dev/null && [ -n "$REMOTE_NAME" ]; then
    WG_IP="$IP"
    break 2
  fi
fi
    done < <(wg show wg0 allowed-ips 2>/dev/null)
    sleep 5
  done
fi

if [ -z "$WG_IP" ]; then
  echo "ERROR: Could not establish WireGuard connectivity to $LOBSTER_NAME"
  exit 1
fi

echo "WireGuard: connected at $WG_IP"

# Wait for SSH
echo "Waiting for SSH..."
for i in $(seq 1 12); do
  if ssh -i /root/.ssh/lobster_admin -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
    "root@$WG_IP" "true" 2>/dev/null; then
    break
  fi
  sleep 5
done

# Pull latest vault
ssh -i /root/.ssh/lobster_admin -o StrictHostKeyChecking=accept-new "root@$WG_IP" \
  "cd /opt/vault && git pull origin main" 2>/dev/null || true

# Refresh secrets
ssh -i /root/.ssh/lobster_admin -o StrictHostKeyChecking=accept-new "root@$WG_IP" \
  "cat > /etc/lobmob/secrets.env && chmod 600 /etc/lobmob/secrets.env" <<SECRETS
GH_TOKEN=$GH_TOKEN
DISCORD_BOT_TOKEN=$DISCORD_BOT_TOKEN
ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY
SECRETS

lobmob-log wake "$LOBSTER_NAME wg_ip=$WG_IP"
echo "Lobster $LOBSTER_NAME is awake at $WG_IP"

# Output lobster info as JSON
cat <<EOF
{
  "lobster_name": "$LOBSTER_NAME",
  "droplet_id": "$DROPLET_ID",
  "wireguard_ip": "$WG_IP",
  "status": "active"
}
EOF
