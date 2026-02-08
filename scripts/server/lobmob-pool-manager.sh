#!/bin/bash
source /etc/lobmob/env
source /etc/lobmob/secrets.env 2>/dev/null || true

POOL_ACTIVE="${POOL_ACTIVE:-1}"
POOL_STANDBY="${POOL_STANDBY:-2}"
MAX_LOBSTERS=10

echo "$(date -Iseconds) Pool manager: target active-idle=$POOL_ACTIVE standby=$POOL_STANDBY"

# Get only fully-provisioned lobsters (tagged -active, not -initializing)
DROPLETS=$(doctl compute droplet list --tag-name "${LOBSTER_TAG}-active" --format ID,Name,Status --no-header 2>/dev/null)
INITIALIZING=$(doctl compute droplet list --tag-name "${LOBSTER_TAG}-initializing" --format Name --no-header 2>/dev/null | wc -l | tr -d ' ')

ACTIVE_BUSY=()
ACTIVE_IDLE=()
STANDBY=()
TOTAL=0

# Pull vault once for task checks
cd /opt/vault 2>/dev/null && git pull origin main --quiet 2>/dev/null || true

while read -r ID NAME STATUS; do
  [ -z "$ID" ] && continue
  TOTAL=$((TOTAL + 1))
  if [ "$STATUS" = "off" ]; then
    STANDBY+=("$NAME")
  elif [ "$STATUS" = "active" ]; then
    # Check if lobster is busy (assigned to an active task in vault)
    BUSY=0
    LOBSTER_SHORT=$(echo "$NAME" | sed 's/^lobster-//')
    if grep -rl "$LOBSTER_SHORT" /opt/vault/010-tasks/active/ 2>/dev/null | head -1 | grep -q .; then
BUSY=1
    fi
    if [ "$BUSY" -eq 1 ]; then
ACTIVE_BUSY+=("$NAME")
    else
ACTIVE_IDLE+=("$NAME")
    fi
  fi
done <<< "$DROPLETS"

BUSY_COUNT=${#ACTIVE_BUSY[@]}
IDLE_COUNT=${#ACTIVE_IDLE[@]}
STANDBY_COUNT=${#STANDBY[@]}

echo "  Current: active-busy=$BUSY_COUNT active-idle=$IDLE_COUNT standby=$STANDBY_COUNT initializing=$INITIALIZING total=$((TOTAL + INITIALIZING))"

# Current config version
CONFIG_VERSION=$(md5sum /usr/local/bin/lobmob-spawn-lobster 2>/dev/null | awk '{print $1}')

# Step 1: Destroy stale standby lobsters (config version mismatch)
for NAME in "${STANDBY[@]}"; do
  # Power on briefly to check? No -- too expensive. Check via doctl tags or stored metadata.
  # Instead, wake and check, or just track version at sleep time.
  # For now, we store config version on the lobster at spawn time and check via SSH after wake.
  # Stale detection happens during wake: if version mismatches, teardown instead.
  true
done

# Step 2: Need more idle active?
if [ "$IDLE_COUNT" -lt "$POOL_ACTIVE" ]; then
  NEED=$((POOL_ACTIVE - IDLE_COUNT))
  echo "  Need $NEED more active-idle lobsters"

  for (( i=0; i<NEED; i++ )); do
    if [ "$TOTAL" -ge "$MAX_LOBSTERS" ]; then
echo "  Hit max lobster limit ($MAX_LOBSTERS), skipping"
break
    fi

    # Prefer waking standby over spawning new
    if [ "$STANDBY_COUNT" -gt 0 ]; then
WAKE_NAME="${STANDBY[0]}"
echo "  Waking standby lobster: $WAKE_NAME"
RESULT=$(lobmob-wake-lobster "$WAKE_NAME" 2>&1) || true
echo "$RESULT"

# Check config version after wake
WG_IP=$(echo "$RESULT" | grep -oP '"wireguard_ip": "\K[^"]+' || true)
if [ -n "$WG_IP" ]; then
  REMOTE_VERSION=$(ssh -i /root/.ssh/lobster_admin -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
    "root@$WG_IP" "cat /etc/lobmob/config-version 2>/dev/null" 2>/dev/null || true)
  if [ -n "$REMOTE_VERSION" ] && [ "$REMOTE_VERSION" != "$CONFIG_VERSION" ]; then
    echo "  Config version mismatch on $WAKE_NAME (got $REMOTE_VERSION, want $CONFIG_VERSION) -- destroying and spawning fresh"
    lobmob-teardown-lobster "$WAKE_NAME"
    lobmob-spawn-lobster
    TOTAL=$((TOTAL))  # net zero: destroyed one, spawned one
  fi
fi

# Remove from standby array
STANDBY=("${STANDBY[@]:1}")
STANDBY_COUNT=${#STANDBY[@]}
    else
echo "  No standby available, spawning new lobster"
lobmob-spawn-lobster
TOTAL=$((TOTAL + 1))
    fi
  done
fi

# Step 3: Too many idle active? Sleep excess.
if [ "$IDLE_COUNT" -gt "$POOL_ACTIVE" ]; then
  EXCESS=$((IDLE_COUNT - POOL_ACTIVE))
  echo "  Sleeping $EXCESS excess idle lobsters"
  for (( i=0; i<EXCESS; i++ )); do
    lobmob-sleep-lobster "${ACTIVE_IDLE[$i]}"
  done
fi

# Step 4: Too many standby? Destroy excess.
# Re-count standby (may have changed from waking)
STANDBY_NOW=$(doctl compute droplet list --tag-name "$LOBSTER_TAG" --format Name,Status --no-header 2>/dev/null \
  | awk '$2 == "off" {print $1}')
STANDBY_COUNT_NOW=$(echo "$STANDBY_NOW" | grep -c . 2>/dev/null || echo 0)
if [ "$STANDBY_COUNT_NOW" -gt "$POOL_STANDBY" ]; then
  EXCESS=$((STANDBY_COUNT_NOW - POOL_STANDBY))
  echo "  Destroying $EXCESS excess standby lobsters"
  echo "$STANDBY_NOW" | head -n "$EXCESS" | while read -r NAME; do
    lobmob-teardown-lobster "$NAME"
  done
fi

# Step 5: Pool underfilled? Spawn to fill.
# Re-count everything
CURRENT_IDLE=$(doctl compute droplet list --tag-name "$LOBSTER_TAG" --format Name,Status --no-header 2>/dev/null \
  | awk '$2 == "active" {print $1}' | wc -l)
CURRENT_STANDBY=$(doctl compute droplet list --tag-name "$LOBSTER_TAG" --format Name,Status --no-header 2>/dev/null \
  | awk '$2 == "off" {print $1}' | wc -l)
CURRENT_TOTAL=$(doctl compute droplet list --tag-name "$LOBSTER_TAG" --format ID --no-header 2>/dev/null | wc -l)
POOL_TARGET=$((POOL_ACTIVE + POOL_STANDBY))
AVAILABLE=$((CURRENT_IDLE + CURRENT_STANDBY - BUSY_COUNT))
if [ "$AVAILABLE" -lt "$POOL_TARGET" ] && [ "$CURRENT_TOTAL" -lt "$MAX_LOBSTERS" ]; then
  NEED=$((POOL_TARGET - AVAILABLE))
  CAPACITY=$((MAX_LOBSTERS - CURRENT_TOTAL))
  SPAWN=$(( NEED < CAPACITY ? NEED : CAPACITY ))
  echo "  Pool underfilled (available=$AVAILABLE, target=$POOL_TARGET). Spawning $SPAWN lobsters."
  for (( i=0; i<SPAWN; i++ )); do
    lobmob-spawn-lobster
  done
fi

# Log convergence result
FINAL_ACTIVE=$(doctl compute droplet list --tag-name "$LOBSTER_TAG" --format Status --no-header 2>/dev/null \
  | grep -c "active" || echo 0)
FINAL_STANDBY=$(doctl compute droplet list --tag-name "$LOBSTER_TAG" --format Status --no-header 2>/dev/null \
  | grep -c "off" || echo 0)
FINAL_TOTAL=$((FINAL_ACTIVE + FINAL_STANDBY))
lobmob-log converge "active=$FINAL_ACTIVE standby=$FINAL_STANDBY total=$FINAL_TOTAL"

echo "$(date -Iseconds) Pool manager: done"
