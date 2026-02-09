ensure_ssh_key

log "Generating WireGuard keypair for lobboss..."
WG_PRIVKEY=$(wg genkey 2>/dev/null || { err "wg not found — install wireguard-tools"; exit 1; })
WG_PUBKEY=$(echo "$WG_PRIVKEY" | wg pubkey)

log "Public key: $WG_PUBKEY"

# Create terraform.tfvars if missing
if [ ! -f "$INFRA_DIR/terraform.tfvars" ]; then
  cp "$INFRA_DIR/terraform.tfvars.example" "$INFRA_DIR/terraform.tfvars"
  portable_sed_i "s|wg_lobboss_public_key.*|wg_lobboss_public_key = \"$WG_PUBKEY\"|" "$INFRA_DIR/terraform.tfvars"
  log "Created infra/terraform.tfvars — fill in vault_repo"
else
  warn "terraform.tfvars already exists — public key: $WG_PUBKEY"
fi

# Create secrets.env if missing
if [ ! -f "$SECRETS_FILE" ]; then
  cp "$PROJECT_DIR/secrets.env.example" "$SECRETS_FILE"
  portable_sed_i "s|^WG_LOBBOSS_PRIVATE_KEY=.*|WG_LOBBOSS_PRIVATE_KEY=$WG_PRIVKEY|" "$SECRETS_FILE"
  log "Created secrets.env — fill in your tokens"
  warn "The WG private key has been written to secrets.env"
  warn "NEVER commit secrets.env to git"
else
  warn "secrets.env already exists — WG private key: (set WG_LOBBOSS_PRIVATE_KEY manually)"
  echo "  $WG_PRIVKEY"
fi

log "Initializing Terraform..."
# Need DO token for terraform init if backend requires it
if [ -f "$SECRETS_FILE" ]; then
  load_secrets 2>/dev/null || true
fi
cd "$INFRA_DIR" && terraform init
