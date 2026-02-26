# lobmob attach — attach to a running lobster: live event stream + inject guidance
# Usage:
#   lobmob attach <job-name>
#   lobmob --env dev attach <job-name>
#
# Requires jq for formatted event output (falls back to raw JSON).

TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
  err "Usage: lobmob attach <job-name>"
  exit 1
fi

LOCAL_PORT="${LOBMOB_CONNECT_PORT:-8080}"

if [[ "$LOBMOB_ENV" == "dev" ]]; then
  KUBE_CONTEXT="do-nyc3-lobmob-dev-k8s"
elif [[ "$LOBMOB_ENV" == "local" ]]; then
  KUBE_CONTEXT="k3d-lobmob-local"
else
  KUBE_CONTEXT="do-nyc3-lobmob-k8s"
fi

# Find the running pod
POD_NAME=$(kubectl --context "$KUBE_CONTEXT" -n lobmob get pods \
  -l "job-name=$TARGET" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -z "$POD_NAME" ]]; then
  err "No running pod found for job: $TARGET"
  log "Active lobster pods:"
  kubectl --context "$KUBE_CONTEXT" -n lobmob get pods -l "app.kubernetes.io/name=lobster" --no-headers 2>/dev/null || true
  exit 1
fi

log "Attaching to pod $POD_NAME ($LOBMOB_ENV)..."
log "Port-forwarding $LOCAL_PORT -> pod:8080..."

# Port-forward in background; clean up on exit
kubectl --context "$KUBE_CONTEXT" -n lobmob port-forward \
  "pod/$POD_NAME" "${LOCAL_PORT}:8080" &>/dev/null &
PF_PID=$!
trap "kill $PF_PID 2>/dev/null; kill \$CURL_PID 2>/dev/null" EXIT

# Wait for sidecar to be ready (up to 5s)
for i in $(seq 1 10); do
  if curl -sf "http://localhost:${LOCAL_PORT}/health" &>/dev/null; then
    break
  fi
  sleep 0.5
done

# Check if IPC is available (returns 503 if LobsterIPC didn't start)
IPC_CHECK=$(curl -sf -o /dev/null -w "%{http_code}" \
  "http://localhost:${LOCAL_PORT}/api/events" \
  --max-time 2 -H "Accept: text/event-stream" 2>/dev/null || echo "000")

if [[ "$IPC_CHECK" == "503" ]]; then
  err "IPC not available on this lobster (started without IPC server)"
  err "This lobster may be running an older image — rebuild to enable attach"
  exit 1
fi

# Event formatting (requires jq; falls back to raw JSON)
HAS_JQ=0
command -v jq &>/dev/null && HAS_JQ=1

_RESET='\033[0m'
_CYAN='\033[0;36m'
_GREEN='\033[0;32m'
_YELLOW='\033[1;33m'
_MAGENTA='\033[0;35m'
_RED='\033[0;31m'

fmt_event() {
  local raw="$1"
  if [[ "$HAS_JQ" == "0" ]]; then
    echo "$raw"
    return
  fi
  local type ts pfx text
  type=$(echo "$raw" | jq -r '.type // "unknown"' 2>/dev/null)
  ts=$(echo "$raw" | jq -r 'if .ts then (.ts | todate | .[11:19]) else "" end' 2>/dev/null)
  pfx="[${ts}] "
  case "$type" in
    turn_start)
      local ep
      ep=$(echo "$raw" | jq -r '.outer_turn')
      echo -e "${_CYAN}${pfx}episode ${ep} start${_RESET}"
      ;;
    tool_start)
      local tool
      tool=$(echo "$raw" | jq -r '.tool')
      echo -e "${_CYAN}${pfx}tool  ${tool}${_RESET}"
      ;;
    tool_denied)
      local tool reason
      tool=$(echo "$raw" | jq -r '.tool')
      reason=$(echo "$raw" | jq -r '.reason // ""')
      echo -e "${_YELLOW}${pfx}tool denied  ${tool} (${reason})${_RESET}"
      ;;
    text)
      text=$(echo "$raw" | jq -r '.text // ""' | tr '\n' ' ' | cut -c1-120)
      echo -e "${_GREEN}${pfx}text  ${text}${_RESET}"
      ;;
    turn_end)
      local ep turns cost
      ep=$(echo "$raw" | jq -r '.outer_turn')
      turns=$(echo "$raw" | jq -r '.inner_turns')
      cost=$(echo "$raw" | jq -r '.cost_usd // 0')
      echo -e "${pfx}episode ${ep} end  turns=${turns} cost=\$${cost}"
      ;;
    verify)
      local missing
      missing=$(echo "$raw" | jq -r 'if (.missing | length) > 0 then "MISSING: " + (.missing | join(", ")) else "PASS" end')
      echo -e "${_YELLOW}${pfx}verify  ${missing}${_RESET}"
      ;;
    inject|inject_received)
      local msgs
      msgs=$(echo "$raw" | jq -r '.messages // [.message] | join(" | ")' 2>/dev/null || echo "")
      echo -e "${_MAGENTA}${pfx}inject  >> ${msgs}${_RESET}"
      ;;
    inject_abort)
      local ep
      ep=$(echo "$raw" | jq -r '.outer_turn')
      echo -e "${_MAGENTA}${pfx}INTERRUPTED — applying operator guidance next episode${_RESET}"
      ;;
    done)
      local is_err cost
      is_err=$(echo "$raw" | jq -r '.is_error')
      cost=$(echo "$raw" | jq -r '.cost_usd // 0')
      if [[ "$is_err" == "true" ]]; then
        echo -e "${_RED}${pfx}ERROR  cost=\$${cost}${_RESET}"
      else
        echo -e "${_GREEN}${pfx}DONE  cost=\$${cost}${_RESET}"
      fi
      ;;
    error)
      local msg
      msg=$(echo "$raw" | jq -r '.message // ""')
      echo -e "${_RED}${pfx}ERROR  ${msg}${_RESET}"
      ;;
    *)
      echo "${pfx}${type}  $(echo "$raw" | jq -c '.' 2>/dev/null | cut -c1-100)"
      ;;
  esac
}

# Auto-exit flag file
DONE_FLAG=$(mktemp)
trap "kill $PF_PID 2>/dev/null; kill \$CURL_PID 2>/dev/null; rm -f $DONE_FLAG" EXIT

log "Streaming events from $TARGET (Ctrl+C to exit)"
echo ""

# SSE reader in background via process substitution
while IFS= read -r line; do
  # SSE lines are "data: {...}"
  if [[ "$line" == data:* ]]; then
    raw="${line#data: }"
    fmt_event "$raw"
    # Check for terminal events
    etype=$(echo "$raw" | jq -r '.type // ""' 2>/dev/null)
    if [[ "$etype" == "done" || "$etype" == "error" ]]; then
      echo ""
      log "Task finished — exiting attach"
      touch "$DONE_FLAG"
    fi
  fi
done < <(curl -sN "http://localhost:${LOCAL_PORT}/api/events" \
  -H "Accept: text/event-stream" 2>/dev/null) &
CURL_PID=$!

# Inject readline loop (foreground)
while true; do
  # Check if task is done
  if [[ -f "$DONE_FLAG" ]] && [[ -s "$DONE_FLAG" || "$(cat "$DONE_FLAG" 2>/dev/null)" == "" ]]; then
    # done flag was touched — check if curl is still running
    if ! kill -0 "$CURL_PID" 2>/dev/null; then
      break
    fi
    # Give the done message a moment to print
    sleep 0.2
    if [[ -e "$DONE_FLAG" ]]; then
      break
    fi
  fi

  read -rp "inject> " MSG 2>/dev/null || break
  [[ -z "$MSG" ]] && continue

  RESP=$(curl -sf -X POST "http://localhost:${LOCAL_PORT}/api/inject" \
    -H "Content-Type: application/json" \
    -d "{\"message\": $(echo "$MSG" | jq -Rs .)}" 2>/dev/null)

  if [[ -n "$RESP" ]]; then
    log "sent — will interrupt at next tool call"
  else
    err "Failed to send injection (IPC may be unavailable)"
  fi
done
