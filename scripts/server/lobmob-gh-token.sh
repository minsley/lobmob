#!/bin/bash
set -euo pipefail

# Load config
if [ -f /etc/lobmob/env ]; then source /etc/lobmob/env; fi

APP_ID="${GH_APP_ID:-}"
INSTALL_ID="${GH_APP_INSTALL_ID:-}"
PEM_FILE="${GH_APP_PEM:-/etc/lobmob/gh-app.pem}"

if [ -z "$APP_ID" ] || [ -z "$INSTALL_ID" ] || [ ! -f "$PEM_FILE" ]; then
  exit 1
fi

# Base64url encode (RFC 4648 section 5)
b64url() { openssl enc -base64 -A | tr '+/' '-_' | tr -d '='; }

NOW=$(date +%s)
IAT=$((NOW - 60))
EXP=$((NOW + 540))

HEADER="eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9"
PAYLOAD=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$IAT" "$EXP" "$APP_ID" | b64url)
SIGNATURE=$(printf '%s' "${HEADER}.${PAYLOAD}" | openssl dgst -binary -sha256 -sign "$PEM_FILE" | b64url)
JWT="${HEADER}.${PAYLOAD}.${SIGNATURE}"

RESPONSE=$(curl -s -X POST \
  -H "Authorization: Bearer $JWT" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/app/installations/${INSTALL_ID}/access_tokens")

if [[ "$RESPONSE" =~ \"token\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
  echo "${BASH_REMATCH[1]}"
else
  echo "ERROR: Failed to get installation token" >&2
  echo "$RESPONSE" >&2
  exit 1
fi
