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

    log "Pushing lobmob-secrets to k8s ($LOBMOB_ENV)..."

    # Build --from-literal args from secrets.env
    # Only push known keys (never push raw file — could contain comments, etc.)
    ARGS=()
    [[ -n "${ANTHROPIC_API_KEY:-}" ]] && ARGS+=(--from-literal="ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}")
    [[ -n "${DISCORD_BOT_TOKEN:-}" ]] && ARGS+=(--from-literal="DISCORD_BOT_TOKEN=${DISCORD_BOT_TOKEN}")
    [[ -n "${GH_TOKEN:-}" ]] && ARGS+=(--from-literal="GH_TOKEN=${GH_TOKEN}")
    [[ -n "${GEMINI_API_KEY:-}" ]] && ARGS+=(--from-literal="GEMINI_API_KEY=${GEMINI_API_KEY}")

    if [[ ${#ARGS[@]} -eq 0 ]]; then
      err "No secrets found in $SECRETS_FILE"
      exit 1
    fi

    kubectl --context "$KUBE_CONTEXT" -n lobmob create secret generic lobmob-secrets \
      "${ARGS[@]}" \
      --dry-run=client -o yaml | kubectl --context "$KUBE_CONTEXT" apply -f -

    log "lobmob-secrets updated (${#ARGS[@]} keys)"
    ;;

  push-broker)
    if [[ ! -f "$SECRETS_FILE" ]]; then
      err "Secrets file not found: $SECRETS_FILE"
      exit 1
    fi

    load_secrets

    log "Pushing lobwife-secrets to k8s ($LOBMOB_ENV)..."

    ARGS=()
    [[ -n "${GH_APP_ID:-}" ]] && ARGS+=(--from-literal="GH_APP_ID=${GH_APP_ID}")
    [[ -n "${GH_APP_INSTALL_ID:-}" ]] && ARGS+=(--from-literal="GH_APP_INSTALL_ID=${GH_APP_INSTALL_ID}")
    [[ -n "${GH_APP_PEM:-}" ]] && ARGS+=(--from-literal="GH_APP_PEM=${GH_APP_PEM}")

    if [[ ${#ARGS[@]} -eq 0 ]]; then
      err "No GitHub App credentials found in $SECRETS_FILE (need GH_APP_ID, GH_APP_INSTALL_ID, GH_APP_PEM)"
      exit 1
    fi

    kubectl --context "$KUBE_CONTEXT" -n lobmob create secret generic lobwife-secrets \
      "${ARGS[@]}" \
      --dry-run=client -o yaml | kubectl --context "$KUBE_CONTEXT" apply -f -

    log "lobwife-secrets updated (${#ARGS[@]} keys)"
    log "Restart lobwife to pick up changes: lobmob restart lobwife"
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
