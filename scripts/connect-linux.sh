#!/bin/bash
# lobmob connect — Linux
# Installs WireGuard, configures tunnel to lobboss, connects, opens web UI.
# Can run standalone or via: lobmob connect
set -euo pipefail

# --- Config discovery ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOBMOB_DIR="${LOBMOB_DIR:-$(dirname "$SCRIPT_DIR")}"
INFRA_DIR="$LOBMOB_DIR/infra"
SECRETS_FILE="$LOBMOB_DIR/secrets.env"
SSH_KEY="${LOBMOB_SSH_KEY:-$HOME/.ssh/lobmob_ed25519}"
WG_CONF="/etc/wireguard/lobmob.conf"
CLIENT_IP="10.0.0.100"
WEB_URL=""  # resolved after lobboss IP is known

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[lobmob]${NC} $*"; }
warn() { echo -e "${YELLOW}[lobmob]${NC} $*"; }
err()  { echo -e "${RED}[lobmob]${NC} $*" >&2; }

get_lobboss_ip() {
  if [ -d "$INFRA_DIR" ] && command -v terraform >/dev/null 2>&1; then
    terraform -chdir="$INFRA_DIR" output -raw lobboss_ip 2>/dev/null && return
  fi
  if [ -f "$LOBMOB_DIR/.lobboss_ip" ]; then
    cat "$LOBMOB_DIR/.lobboss_ip" && return
  fi
  echo ""
}

# --- Step 1: Install WireGuard ---
log "Step 1 — WireGuard"
if command -v wg >/dev/null 2>&1; then
  echo -e "  ${GREEN}✓${NC} wireguard-tools installed"
else
  if command -v apt-get >/dev/null 2>&1; then
    log "  Installing wireguard-tools via apt..."
    sudo apt-get update -qq && sudo apt-get install -y wireguard-tools
  elif command -v dnf >/dev/null 2>&1; then
    log "  Installing wireguard-tools via dnf..."
    sudo dnf install -y wireguard-tools
  elif command -v pacman >/dev/null 2>&1; then
    log "  Installing wireguard-tools via pacman..."
    sudo pacman -S --noconfirm wireguard-tools
  else
    err "No supported package manager found (apt, dnf, pacman)"
    err "Install wireguard-tools manually and re-run"
    exit 1
  fi
fi

# --- Step 2: Configure tunnel ---
log "Step 2 — Tunnel config"
if [ -f "$WG_CONF" ]; then
  echo -e "  ${GREEN}✓${NC} Config exists at $WG_CONF"
else
  log "  Generating WireGuard keypair..."
  PRIVKEY=$(wg genkey)
  PUBKEY=$(echo "$PRIVKEY" | wg pubkey)

  LOBBOSS_IP=$(get_lobboss_ip)
  if [ -z "$LOBBOSS_IP" ]; then
    read -rp "  Lobboss public IP: " LOBBOSS_IP
  fi

  log "  Registering peer on lobboss..."
  if [ ! -f "$SSH_KEY" ]; then
    err "SSH key not found at $SSH_KEY"
    err "Run 'lobmob bootstrap' first, or set LOBMOB_SSH_KEY"
    exit 1
  fi

  LOBBOSS_WG_PUBKEY=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "root@$LOBBOSS_IP" bash <<REGISTER
# Add peer to live WG interface
wg set wg0 peer "$PUBKEY" allowed-ips "$CLIENT_IP/32"

# Persist to config file
if ! grep -q "$PUBKEY" /etc/wireguard/wg0.conf 2>/dev/null; then
  cat >> /etc/wireguard/wg0.conf <<PEEREOF

[Peer]
# Operator workstation
PublicKey = $PUBKEY
AllowedIPs = $CLIENT_IP/32
PEEREOF
fi

# Return lobboss WG public key
wg show wg0 public-key
REGISTER
  )

  log "  Writing config to $WG_CONF..."
  sudo mkdir -p /etc/wireguard
  sudo tee "$WG_CONF" > /dev/null <<CONF
[Interface]
PrivateKey = $PRIVKEY
Address = $CLIENT_IP/24

[Peer]
PublicKey = $LOBBOSS_WG_PUBKEY
AllowedIPs = 10.0.0.0/24
Endpoint = $LOBBOSS_IP:51820
PersistentKeepalive = 25
CONF
  sudo chmod 600 "$WG_CONF"
  echo -e "  ${GREEN}✓${NC} Config written"
fi

# --- Step 3: Connect ---
log "Step 3 — Connect"
if sudo wg show lobmob >/dev/null 2>&1; then
  echo -e "  ${GREEN}✓${NC} Tunnel already up"
else
  log "  Bringing up tunnel..."
  sudo wg-quick up lobmob
fi

# Wait for connectivity
log "  Waiting for lobboss..."
for i in $(seq 1 10); do
  if ping -c 1 -W 2 10.0.0.1 >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} Connected to lobboss (10.0.0.1)"
    break
  fi
  if [ "$i" -eq 10 ]; then
    err "Could not reach lobboss at 10.0.0.1 — check WireGuard config"
    exit 1
  fi
  sleep 2
done

# --- Step 4: Open web UI ---
log "Step 4 — Web UI"
LOBBOSS_IP=$(get_lobboss_ip)
if [ -z "$LOBBOSS_IP" ]; then
  LOBBOSS_IP=$(grep Endpoint "$WG_CONF" 2>/dev/null | head -1 | sed 's/.*= *//;s/:.*//')
fi
WEB_URL="https://$LOBBOSS_IP"
if curl -sk -o /dev/null -w "%{http_code}" "$WEB_URL/health" 2>/dev/null | grep -q 200; then
  echo -e "  ${GREEN}✓${NC} Web UI reachable"
  log "Opening $WEB_URL ..."
  xdg-open "$WEB_URL" 2>/dev/null || sensible-browser "$WEB_URL" 2>/dev/null || \
    warn "Could not open browser. Visit: $WEB_URL"
else
  warn "Web UI not responding at $WEB_URL (may need cert setup first)"
  warn "Try: xdg-open $WEB_URL"
fi

echo ""
log "Connected to lobmob swarm via WireGuard"
log "  Web UI:  $WEB_URL"
log "  SSH:     ssh -i $SSH_KEY root@10.0.0.1"
log "  Disconnect: sudo wg-quick down lobmob"
