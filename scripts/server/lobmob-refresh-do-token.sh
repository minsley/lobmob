#!/bin/bash
set -euo pipefail

ENV_FILE="/etc/lobmob/secrets.env"
WEB_ENV="/etc/lobmob/web.env"

# Load current tokens
source "$ENV_FILE"
source "$WEB_ENV" 2>/dev/null || true

REFRESH_TOKEN="${DO_OAUTH_REFRESH:-}"
CLIENT_ID="${DO_OAUTH_CLIENT_ID:-}"
CLIENT_SECRET="${DO_OAUTH_CLIENT_SECRET:-}"

if [ -z "$REFRESH_TOKEN" ] || [ -z "$CLIENT_ID" ] || [ -z "$CLIENT_SECRET" ]; then
  echo "DO OAuth not configured, skipping refresh"
  exit 0
fi

RESPONSE=$(curl -s -X POST "https://cloud.digitalocean.com/v1/oauth/token" \
  -d "grant_type=refresh_token" \
  -d "refresh_token=$REFRESH_TOKEN" \
  -d "client_id=$CLIENT_ID" \
  -d "client_secret=$CLIENT_SECRET")

ACCESS_TOKEN=$(echo "$RESPONSE" | jq -r '.access_token // empty')
NEW_REFRESH=$(echo "$RESPONSE" | jq -r '.refresh_token // empty')

if [ -z "$ACCESS_TOKEN" ]; then
  echo "ERROR: Failed to refresh DO token"
  echo "$RESPONSE"
  lobmob-log error "DO OAuth token refresh failed"
  exit 1
fi

# Update tokens in secrets.env
if grep -q "^DO_OAUTH_TOKEN=" "$ENV_FILE"; then
  sed -i "s|^DO_OAUTH_TOKEN=.*|DO_OAUTH_TOKEN=$ACCESS_TOKEN|" "$ENV_FILE"
else
  echo "DO_OAUTH_TOKEN=$ACCESS_TOKEN" >> "$ENV_FILE"
fi
if grep -q "^DO_OAUTH_REFRESH=" "$ENV_FILE"; then
  sed -i "s|^DO_OAUTH_REFRESH=.*|DO_OAUTH_REFRESH=$NEW_REFRESH|" "$ENV_FILE"
else
  echo "DO_OAUTH_REFRESH=$NEW_REFRESH" >> "$ENV_FILE"
fi

lobmob-log token-refresh "DO OAuth token refreshed successfully"
echo "DO OAuth token refreshed"
