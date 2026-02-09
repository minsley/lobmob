LOBBOSS_IP=$(get_lobboss_ip)
if [ -z "$LOBBOSS_IP" ]; then
  err "Lobboss not deployed. Run: lobmob deploy"
  exit 1
fi

if [ $# -eq 0 ]; then
  # No args: show current pool config and state
  log "Pool config and state:"
  lobmob_ssh "root@$LOBBOSS_IP" "grep POOL_ /etc/lobmob/env"
  lobmob_ssh "root@$LOBBOSS_IP" "lobmob-fleet-status" 2>/dev/null | grep -A 10 "Pool State"
  return
fi

# Parse args: pool active N standby N
local NEW_ACTIVE="" NEW_STANDBY=""
while [ $# -gt 0 ]; do
  case "$1" in
    active)  shift; NEW_ACTIVE="$1" ;;
    standby) shift; NEW_STANDBY="$1" ;;
    *)       err "Unknown pool arg: $1"; exit 1 ;;
  esac
  shift
done

if [ -n "$NEW_ACTIVE" ]; then
  log "Setting POOL_ACTIVE=$NEW_ACTIVE on lobboss..."
  lobmob_ssh "root@$LOBBOSS_IP" "sed -i 's/^POOL_ACTIVE=.*/POOL_ACTIVE=$NEW_ACTIVE/' /etc/lobmob/env"
fi
if [ -n "$NEW_STANDBY" ]; then
  log "Setting POOL_STANDBY=$NEW_STANDBY on lobboss..."
  lobmob_ssh "root@$LOBBOSS_IP" "sed -i 's/^POOL_STANDBY=.*/POOL_STANDBY=$NEW_STANDBY/' /etc/lobmob/env"
fi

log "Updated pool config:"
lobmob_ssh "root@$LOBBOSS_IP" "grep POOL_ /etc/lobmob/env"
