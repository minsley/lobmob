# HOST must be set by caller before sourcing this file
HOST="${HOST:?HOST must be set}"

# Wait for cloud-init to fully complete (runcmd installs gh, node, doctl)
log "Waiting for cloud-init on $HOST..."
for _ci_i in $(seq 1 60); do
  _ci_status=$(ssh -i "$LOBMOB_SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "root@$HOST" "cloud-init status" 2>/dev/null || echo "pending")
  if echo "$_ci_status" | grep -qE "done|degraded"; then
    log "  cloud-init: complete"
    break
  fi
  if [ "$_ci_i" -eq 60 ]; then
    warn "  cloud-init still running after 300s — proceeding anyway"
  fi
  sleep 5
done

# Set up SSH multiplexing to avoid connection resets from rapid SCP
_SSH_MUX="/tmp/lobmob-ssh-mux-$HOST"
export LOBMOB_SSH_MUX_OPTS="-o ControlMaster=auto -o ControlPath=$_SSH_MUX -o ControlPersist=120"
lobmob_ssh $LOBMOB_SSH_MUX_OPTS "root@$HOST" true 2>/dev/null || true  # open master connection
# Override lobmob_ssh and scp for this session to use the mux
lobmob_ssh() { ssh -i "$LOBMOB_SSH_KEY" -o StrictHostKeyChecking=accept-new $LOBMOB_SSH_MUX_OPTS "$@"; }
_lobmob_scp() { scp -i "$LOBMOB_SSH_KEY" -o StrictHostKeyChecking=accept-new $LOBMOB_SSH_MUX_OPTS "$@"; }

log "Pushing secrets to $HOST..."

# 1. Push secrets.env (service tokens)
lobmob_ssh "root@$HOST" "cat > /etc/lobmob/secrets.env && chmod 600 /etc/lobmob/secrets.env" <<EOF
DO_TOKEN=$DO_TOKEN
GH_TOKEN=${GH_TOKEN:-}
DISCORD_BOT_TOKEN=$DISCORD_BOT_TOKEN
ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY
EOF
log "  secrets.env: pushed"

# 1b. Push GitHub App PEM if configured
if [ -n "${GH_APP_PEM_B64:-}" ]; then
  echo "$GH_APP_PEM_B64" | base64 -d | \
    lobmob_ssh "root@$HOST" "cat > /etc/lobmob/gh-app.pem && chmod 600 /etc/lobmob/gh-app.pem"
  # Write App config to env (idempotent)
  lobmob_ssh "root@$HOST" bash <<GHAPP
grep -q "^GH_APP_ID=" /etc/lobmob/env 2>/dev/null && sed -i "s|^GH_APP_ID=.*|GH_APP_ID=${GH_APP_ID}|" /etc/lobmob/env || echo "GH_APP_ID=${GH_APP_ID}" >> /etc/lobmob/env
grep -q "^GH_APP_INSTALL_ID=" /etc/lobmob/env 2>/dev/null && sed -i "s|^GH_APP_INSTALL_ID=.*|GH_APP_INSTALL_ID=${GH_APP_INSTALL_ID}|" /etc/lobmob/env || echo "GH_APP_INSTALL_ID=${GH_APP_INSTALL_ID}" >> /etc/lobmob/env
GHAPP
  log "  GitHub App PEM + config: pushed"
fi

# 1c. Push DO OAuth web.env if configured
if [ -n "${DO_OAUTH_CLIENT_ID:-}" ]; then
  lobmob_ssh "root@$HOST" "cat > /etc/lobmob/web.env && chmod 600 /etc/lobmob/web.env" <<WEBENV
DO_OAUTH_CLIENT_ID=$DO_OAUTH_CLIENT_ID
DO_OAUTH_CLIENT_SECRET=$DO_OAUTH_CLIENT_SECRET
WEBENV
  log "  web.env (DO OAuth): pushed"
fi

# 2. Push vault deploy key
echo "$VAULT_DEPLOY_KEY_B64" | base64 -d | \
  lobmob_ssh "root@$HOST" "cat > /root/.ssh/vault_key && chmod 600 /root/.ssh/vault_key"
log "  deploy key: pushed"

# 3. Push WireGuard private key into config
lobmob_ssh "root@$HOST" bash <<WGSETUP
  if [ -f /etc/wireguard/wg0.conf.template ]; then
    sed "s|__WG_PRIVATE_KEY__|$WG_LOBBOSS_PRIVATE_KEY|" \
      /etc/wireguard/wg0.conf.template > /etc/wireguard/wg0.conf
    chmod 600 /etc/wireguard/wg0.conf
    rm /etc/wireguard/wg0.conf.template
  fi
WGSETUP
log "  WireGuard key: pushed"

# 4. Deploy server scripts
log "Deploying server scripts..."
for script in "$SCRIPT_DIR"/server/*.sh "$SCRIPT_DIR"/server/*.js; do
  [ -f "$script" ] || continue
  _lobmob_scp "$script" "root@$HOST:/usr/local/bin/$(basename "$script" | sed 's/\.sh$//;s/\.js$//')"
done
lobmob_ssh "root@$HOST" "chmod 755 /usr/local/bin/lobmob-*"
log "  server scripts: deployed"

# 5. Deploy systemd service files
for svc in "$SCRIPT_DIR"/server/*.service; do
  [ -f "$svc" ] || continue
  _lobmob_scp "$svc" "root@$HOST:/etc/systemd/system/$(basename "$svc")"
done
lobmob_ssh "root@$HOST" "systemctl daemon-reload"
log "  systemd services: deployed"

# 6. Run the provision script on lobboss
log "Running provision script..."
lobmob_ssh "root@$HOST" "/usr/local/bin/lobmob-provision"

# Close SSH multiplexing master connection
ssh -O exit -o ControlPath="$_SSH_MUX" "root@$HOST" 2>/dev/null || true

log "Secrets provisioned successfully"
