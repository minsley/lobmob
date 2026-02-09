LOBBOSS_IP=$(get_lobboss_ip)
if [ -z "$LOBBOSS_IP" ]; then
  err "Lobboss not deployed. Run: lobmob deploy"
  exit 1
fi

# Name generator — TYPE-NNN-adjective-name (name auto-generated on lobboss)
# Parse --type flag from spawn args
local LOBSTER_TYPE="research"
local LOBSTER_NAME=""
local _spawn_args=("$@")
local _filtered=()
local _i=0
while [ $_i -lt ${#_spawn_args[@]} ]; do
  if [ "${_spawn_args[$_i]}" = "--type" ] && [ $((_i + 1)) -lt ${#_spawn_args[@]} ]; then
    LOBSTER_TYPE="${_spawn_args[$((_i + 1))]}"
    _i=$((_i + 2))
  else
    _filtered+=("${_spawn_args[$_i]}")
    _i=$((_i + 1))
  fi
done
LOBSTER_NAME="${_filtered[0]:-}"
log "Spawning lobster (type: $LOBSTER_TYPE) via lobboss..."
lobmob_ssh "root@$LOBBOSS_IP" "lobmob-spawn-lobster $LOBSTER_NAME '' $LOBSTER_TYPE"
