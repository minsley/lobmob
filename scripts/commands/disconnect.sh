if sudo wg show lobmob >/dev/null 2>&1; then
  log "Disconnecting WireGuard tunnel..."
  sudo wg-quick down lobmob
  log "Disconnected"
else
  warn "No active lobmob tunnel"
fi
