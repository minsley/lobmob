if [ -z "${1:-}" ]; then
  err "Usage: lobmob ssh-lobster <wireguard-ip or lobster-id>"
  exit 1
fi
LOBBOSS_IP=$(get_lobboss_ip)
TARGET="$1"
if [[ ! "$TARGET" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  TARGET=$(lobmob_ssh "root@$LOBBOSS_IP" "grep '$TARGET' /opt/vault/040-fleet/registry.md | grep -oP 'wg_ip: \K\S+'" 2>/dev/null || echo "$TARGET")
fi
log "Connecting to lobster at $TARGET via lobboss tunnel..."
lobmob_ssh -o ProxyJump="root@$LOBBOSS_IP" "root@$TARGET"
