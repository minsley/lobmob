# lobmob verify — post-deploy verification checks
# Usage:
#   lobmob verify              -> verify all services
#   lobmob verify lobwife      -> verify lobwife only

if [[ "$LOBMOB_ENV" == "dev" ]]; then
  KUBE_CONTEXT="do-nyc3-lobmob-dev-k8s"
else
  KUBE_CONTEXT="do-nyc3-lobmob-k8s"
fi

TARGET="${1:-all}"
PASS=0
FAIL=0

pass() {
  log "  PASS  $1"
  PASS=$((PASS + 1))
}

fail() {
  err "  FAIL  $1"
  FAIL=$((FAIL + 1))
}

check() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    pass "$label"
  else
    fail "$label"
  fi
}

verify_lobwife() {
  log "Verifying lobwife ($LOBMOB_ENV)..."
  echo ""

  # Pod running
  log "Pod status:"
  check "lobwife pod exists" \
    kubectl --context "$KUBE_CONTEXT" -n lobmob get pods -l app.kubernetes.io/name=lobwife --no-headers

  POD=$(kubectl --context "$KUBE_CONTEXT" -n lobmob get pods -l app.kubernetes.io/name=lobwife \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [[ -n "$POD" ]]; then
    PHASE=$(kubectl --context "$KUBE_CONTEXT" -n lobmob get pod "$POD" \
      -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [[ "$PHASE" == "Running" ]]; then pass "pod phase is Running"; else fail "pod phase is Running (got: $PHASE)"; fi

    READY=$(kubectl --context "$KUBE_CONTEXT" -n lobmob get pod "$POD" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    if [[ "$READY" == "True" ]]; then pass "pod is Ready"; else fail "pod is Ready (got: $READY)"; fi
  fi
  echo ""

  # HTTP API via port-forward
  log "HTTP API:"
  kubectl --context "$KUBE_CONTEXT" -n lobmob port-forward svc/lobwife 18080:8080 &>/dev/null &
  PF_PID=$!
  # Wait for port-forward to be ready
  for i in $(seq 1 10); do
    if curl -sf http://localhost:18080/health >/dev/null 2>&1; then break; fi
    sleep 1
  done

  # Health endpoint
  HEALTH=$(curl -sf http://localhost:18080/health 2>/dev/null || true)
  if [[ "$HEALTH" == *'"status"'* && "$HEALTH" == *'"ok"'* ]]; then
    pass "GET /health returns ok"
  else
    fail "GET /health returns ok"
  fi

  # API status
  STATUS=$(curl -sf http://localhost:18080/api/status 2>/dev/null || true)
  if [[ "$STATUS" == *'"jobs"'* ]]; then pass "GET /api/status returns jobs"; else fail "GET /api/status returns jobs"; fi

  # Jobs list
  JOBS=$(curl -sf http://localhost:18080/api/jobs 2>/dev/null || true)
  if [[ "$JOBS" == *'"task-manager"'* ]]; then pass "GET /api/jobs lists task-manager"; else fail "GET /api/jobs lists task-manager"; fi
  if [[ "$JOBS" == *'"review-prs"'* ]]; then pass "GET /api/jobs lists review-prs"; else fail "GET /api/jobs lists review-prs"; fi
  if [[ "$JOBS" == *'"flush-logs"'* ]]; then pass "GET /api/jobs lists flush-logs"; else fail "GET /api/jobs lists flush-logs"; fi

  # Individual job detail
  JOB_DETAIL=$(curl -sf http://localhost:18080/api/jobs/task-manager 2>/dev/null || true)
  if [[ "$JOB_DETAIL" == *'"schedule"'* ]]; then pass "GET /api/jobs/task-manager returns detail"; else fail "GET /api/jobs/task-manager returns detail"; fi

  # Web dashboard
  DASHBOARD=$(curl -sf http://localhost:18080/ 2>/dev/null || true)
  if [[ "$DASHBOARD" == *'lobwife'* ]]; then pass "GET / returns HTML dashboard"; else fail "GET / returns HTML dashboard"; fi

  # Manual trigger
  TRIGGER=$(curl -sf -X POST http://localhost:18080/api/jobs/flush-logs/trigger 2>/dev/null || true)
  if [[ "$TRIGGER" == *'triggered'* ]]; then pass "POST /api/jobs/flush-logs/trigger works"; else fail "POST /api/jobs/flush-logs/trigger works"; fi
  echo ""

  # Token broker
  log "Token broker:"
  BROKER_STATUS=$(curl -sf http://localhost:18080/health 2>/dev/null || true)
  if [[ "$BROKER_STATUS" == *'"broker"'* ]]; then pass "broker status in /health"; else fail "broker status in /health"; fi

  # Register test task
  REG=$(curl -sf -X POST http://localhost:18080/api/tasks/verify-test/register \
    -H "Content-Type: application/json" \
    -d '{"repos": ["test/verify-repo"], "lobster_type": "test"}' 2>/dev/null || true)
  if [[ "$REG" == *'"registered"'* ]]; then pass "POST /api/tasks/{id}/register"; else fail "POST /api/tasks/{id}/register"; fi

  # List tasks
  TASKS=$(curl -sf http://localhost:18080/api/tasks 2>/dev/null || true)
  if [[ "$TASKS" == *'"verify-test"'* ]]; then pass "GET /api/tasks lists registered task"; else fail "GET /api/tasks lists registered task"; fi

  # Request token (may return 503 if no PEM — that's valid, broker is reachable)
  TOKEN_RESP=$(curl -s -X POST http://localhost:18080/api/token \
    -H "Content-Type: application/json" \
    -d '{"task_id": "verify-test"}' 2>/dev/null || true)
  if [[ "$TOKEN_RESP" == *'"token"'* ]]; then
    pass "POST /api/token returns scoped token"
  elif [[ "$TOKEN_RESP" == *'not configured'* ]]; then
    pass "POST /api/token reachable (no PEM configured)"
  else
    fail "POST /api/token"
  fi

  # Deregister
  DEREG=$(curl -sf -X DELETE http://localhost:18080/api/tasks/verify-test 2>/dev/null || true)
  if [[ "$DEREG" == *'"removed"'* ]]; then pass "DELETE /api/tasks/{id}"; else fail "DELETE /api/tasks/{id}"; fi

  # Audit log
  AUDIT=$(curl -sf http://localhost:18080/api/token/audit 2>/dev/null || true)
  if [[ "$AUDIT" == *'"task_registered"'* ]]; then pass "GET /api/token/audit shows events"; else fail "GET /api/token/audit shows events"; fi

  kill "$PF_PID" 2>/dev/null || true
  wait "$PF_PID" 2>/dev/null || true
  echo ""

  # Daemon logs
  if [[ -n "$POD" ]]; then
    log "Daemon logs (last 10 lines):"
    kubectl --context "$KUBE_CONTEXT" -n lobmob exec "$POD" -- tail -10 /home/lobwife/state/daemon.log 2>/dev/null || echo "  (no daemon log yet)"
    echo ""
  fi

  # No old cronjobs
  log "CronJob cleanup:"
  CRON_COUNT=$(kubectl --context "$KUBE_CONTEXT" -n lobmob get cronjobs --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$CRON_COUNT" == "0" ]]; then
    pass "No CronJobs found (migrated to lobwife)"
  else
    warn "  WARN  $CRON_COUNT CronJobs still exist — delete with: kubectl -n lobmob delete cronjobs --all"
  fi
  echo ""
}

verify_lobboss() {
  log "Verifying lobboss ($LOBMOB_ENV)..."
  check "lobboss pod running" \
    kubectl --context "$KUBE_CONTEXT" -n lobmob get pods -l app.kubernetes.io/name=lobboss --field-selector=status.phase=Running --no-headers
  echo ""
}

verify_lobsigliere() {
  log "Verifying lobsigliere ($LOBMOB_ENV)..."
  check "lobsigliere pod running" \
    kubectl --context "$KUBE_CONTEXT" -n lobmob get pods -l app.kubernetes.io/name=lobsigliere --field-selector=status.phase=Running --no-headers
  echo ""
}

case "$TARGET" in
  lobwife)
    verify_lobwife
    ;;
  lobboss)
    verify_lobboss
    ;;
  lobsigliere)
    verify_lobsigliere
    ;;
  all)
    verify_lobboss
    verify_lobsigliere
    verify_lobwife
    ;;
  *)
    err "Unknown target: $TARGET"
    err "Valid targets: lobwife, lobboss, lobsigliere, all"
    exit 1
    ;;
esac

log "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
