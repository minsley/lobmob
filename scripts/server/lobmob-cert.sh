#!/bin/bash
set -euo pipefail
CERT_DIR="/etc/lobmob/certs"
LEGO_DIR="/etc/lobmob/lego"
EMAIL="${ALERT_EMAIL:-admin@lobmob.swarm}"
mkdir -p "$CERT_DIR" "$LEGO_DIR"

# Get the reserved (public) IP
PUBLIC_IP=$(curl -s http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address)
if [ -z "$PUBLIC_IP" ]; then
  echo "ERROR: Could not determine public IP" >&2
  exit 1
fi

# Install lego if not present
if ! command -v lego >/dev/null 2>&1; then
  LEGO_VERSION="4.21.0"
  curl -fsSL "https://github.com/go-acme/lego/releases/download/v${LEGO_VERSION}/lego_v${LEGO_VERSION}_linux_amd64.tar.gz" \
    | tar -xz -C /usr/local/bin lego
  echo "lego installed"
fi

# Issue or renew certificate
if [ -f "$LEGO_DIR/certificates/$PUBLIC_IP.crt" ]; then
  lego --path "$LEGO_DIR" \
    --email "$EMAIL" --accept-tos \
    --domains "$PUBLIC_IP" --disable-cn \
    --http --http.port :80 \
    renew --days 3 --profile shortlived 2>&1 || true
else
  lego --path "$LEGO_DIR" \
    --email "$EMAIL" --accept-tos \
    --domains "$PUBLIC_IP" --disable-cn \
    --http --http.port :80 \
    run --profile shortlived 2>&1
fi

# Copy certs to the expected location
if [ -f "$LEGO_DIR/certificates/$PUBLIC_IP.crt" ]; then
  cp "$LEGO_DIR/certificates/$PUBLIC_IP.crt" "$CERT_DIR/cert.pem"
  cp "$LEGO_DIR/certificates/$PUBLIC_IP.key" "$CERT_DIR/key.pem"
  chmod 600 "$CERT_DIR/key.pem"
  # Restart web server to pick up new certs
  systemctl restart lobmob-web 2>/dev/null || true
  echo "Certificate issued/renewed for $PUBLIC_IP"
else
  echo "WARNING: No certificate found after lego run" >&2
fi
