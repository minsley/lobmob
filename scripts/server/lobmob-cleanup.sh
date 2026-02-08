#!/bin/bash
source /etc/lobmob/env
source /etc/lobmob/secrets.env 2>/dev/null || true

POOL_ACTIVE="${POOL_ACTIVE:-1}"
POOL_STANDBY="${POOL_STANDBY:-2}"
HARD_MAX_HOURS=24
NOW=$(date +%s)

# Only manage fully-provisioned lobsters (tagged -active, not -initializing)
DROPLETS=$(doctl compute droplet list --tag-name "${LOBSTER_TAG}-active" --format ID,Name,Status,Created --no-header 2>/dev/null)
if [ -z "$DROPLETS" ]; then
  exit 0
fi

# Classify droplets
ACTIVE_IDLE=()
STANDBY=()
SLEPT=0
DESTROYED=0
AGED_OUT=0

while read -r ID NAME STATUS CREATED; do
  # Hard ceiling: destroy ANY lobster older than 24h
  CREATED_TS=$(date -d "$CREATED" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$CREATED" +%s 2>/dev/null)
  AGE_HOURS=$(( (NOW - CREATED_TS) / 3600 ))
  if [ "$AGE_HOURS" -ge "$HARD_MAX_HOURS" ]; then
    echo "Destroying lobster $NAME (age: ${AGE_HOURS}h exceeds ${HARD_MAX_HOURS}h ceiling)"
    lobmob-teardown-lobster "$NAME"
    AGED_OUT=$((AGED_OUT + 1))
    continue
  fi

  if [ "$STATUS" = "off" ]; then
    STANDBY+=("$NAME")
  elif [ "$STATUS" = "active" ]; then
    # Check if busy (has active task in vault)
    BUSY=0
    if ls /opt/vault/010-tasks/active/*"$NAME"* 2>/dev/null | grep -q .; then
BUSY=1
    fi
    if [ "$BUSY" -eq 0 ]; then
ACTIVE_IDLE+=("$NAME")
    fi
  fi
done <<< "$DROPLETS"

# Sleep excess idle lobsters beyond POOL_ACTIVE
IDLE_COUNT=${#ACTIVE_IDLE[@]}
if [ "$IDLE_COUNT" -gt "$POOL_ACTIVE" ]; then
  EXCESS=$(( IDLE_COUNT - POOL_ACTIVE ))
  echo "Sleeping $EXCESS excess idle lobsters (have $IDLE_COUNT, want $POOL_ACTIVE)"
  for (( i=0; i<EXCESS; i++ )); do
    lobmob-sleep-lobster "${ACTIVE_IDLE[$i]}"
    SLEPT=$((SLEPT + 1))
  done
fi

# Destroy excess standby lobsters beyond POOL_STANDBY
STANDBY_COUNT=${#STANDBY[@]}
if [ "$STANDBY_COUNT" -gt "$POOL_STANDBY" ]; then
  EXCESS=$(( STANDBY_COUNT - POOL_STANDBY ))
  echo "Destroying $EXCESS excess standby lobsters (have $STANDBY_COUNT, want $POOL_STANDBY)"
  for (( i=0; i<EXCESS; i++ )); do
    lobmob-teardown-lobster "${STANDBY[$i]}"
    DESTROYED=$((DESTROYED + 1))
  done
fi

lobmob-log cleanup "slept=$SLEPT destroyed=$DESTROYED aged_out=$AGED_OUT"
