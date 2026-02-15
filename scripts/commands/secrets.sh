# lobmob secrets — manage k8s secrets from secrets.env
# Usage:
#   lobmob secrets push           -> push secrets.env to k8s lobmob-secrets
#   lobmob secrets push-broker    -> push GitHub App credentials to lobwife-secrets
#   lobmob secrets show           -> show which secrets are set (names only, not values)

if [[ "$LOBMOB_ENV" == "dev" ]]; then
  KUBE_CONTEXT="do-nyc3-lobmob-dev-k8s"
else
  KUBE_CONTEXT="do-nyc3-lobmob-k8s"
fi

SUBCMD="${1:-}"
if [[ -z "$SUBCMD" ]]; then
  err "Usage: lobmob secrets <push|push-broker|show>"
  exit 1
fi

case "$SUBCMD" in
  push)
    if [[ ! -f "$SECRETS_FILE" ]]; then
      err "Secrets file not found: $SECRETS_FILE"
      exit 1
    fi
    load_secrets
    push_k8s_secrets
    ;;

  push-broker)
    warn "Deprecated: 'push-broker' is now included in 'push'. Running 'push' instead."
    if [[ ! -f "$SECRETS_FILE" ]]; then
      err "Secrets file not found: $SECRETS_FILE"
      exit 1
    fi
    load_secrets
    push_k8s_secrets
    ;;

  show)
    if [[ ! -f "$SECRETS_FILE" ]]; then
      err "Secrets file not found: $SECRETS_FILE"
      exit 1
    fi

    log "Secrets in $SECRETS_FILE:"
    while IFS='=' read -r key value; do
      # Skip comments and blank lines
      [[ "$key" =~ ^[[:space:]]*# ]] && continue
      [[ -z "$key" ]] && continue
      key=$(echo "$key" | xargs)  # trim whitespace
      if [[ -n "$value" && "$value" != "..." && "$value" != *"_..."* ]]; then
        log "  $key = (set, ${#value} chars)"
      else
        warn "  $key = (empty/placeholder)"
      fi
    done < "$SECRETS_FILE"

    echo ""
    log "k8s secrets ($LOBMOB_ENV):"
    kubectl --context "$KUBE_CONTEXT" -n lobmob get secrets --no-headers 2>/dev/null | while read -r name type data age; do
      log "  $name ($type, $data, $age)"
    done
    ;;

  *)
    err "Unknown subcommand: $SUBCMD"
    err "Usage: lobmob secrets <push|push-broker|show>"
    exit 1
    ;;
esac
