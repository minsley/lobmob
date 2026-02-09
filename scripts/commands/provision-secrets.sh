load_secrets
LOBBOSS_IP=$(get_lobboss_ip)
if [ -z "$LOBBOSS_IP" ]; then
  err "Lobboss not deployed. Run: lobmob deploy"
  exit 1
fi
HOST="$LOBBOSS_IP"
source "$SCRIPT_DIR/commands/provision-secrets-to.sh"
