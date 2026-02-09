# HOST must be set by caller before sourcing this file
HOST="${HOST:?HOST must be set}"

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
  # Write App config to env
  lobmob_ssh "root@$HOST" bash <<GHAPP
echo "GH_APP_ID=${GH_APP_ID}" >> /etc/lobmob/env
echo "GH_APP_INSTALL_ID=${GH_APP_INSTALL_ID}" >> /etc/lobmob/env
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
  scp -i "$LOBMOB_SSH_KEY" -o StrictHostKeyChecking=accept-new \
    "$script" "root@$HOST:/usr/local/bin/$(basename "$script" | sed 's/\.sh$//;s/\.js$//')"
done
lobmob_ssh "root@$HOST" "chmod 755 /usr/local/bin/lobmob-*"
log "  server scripts: deployed"

# 5. Deploy systemd service files
for svc in "$SCRIPT_DIR"/server/*.service; do
  [ -f "$svc" ] || continue
  scp -i "$LOBMOB_SSH_KEY" -o StrictHostKeyChecking=accept-new \
    "$svc" "root@$HOST:/etc/systemd/system/$(basename "$svc")"
done
lobmob_ssh "root@$HOST" "systemctl daemon-reload"
log "  systemd services: deployed"

# 6. Run the provision script on lobboss
log "Running provision script..."
lobmob_ssh "root@$HOST" "/usr/local/bin/lobmob-provision"

log "Secrets provisioned successfully"
