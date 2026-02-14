# lobmob setup github — create a GitHub App via the manifest flow
# Usage:
#   lobmob setup github [--name NAME] [--org ORG]
#
# Creates a GitHub App with the permissions needed by the lobmob fleet,
# writes credentials to the secrets file, and guides installation.

APP_NAME="lobmob-fleet"
GITHUB_ORG=""
CALLBACK_PORT=3456

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) APP_NAME="$2"; shift 2 ;;
    --org)  GITHUB_ORG="$2"; shift 2 ;;
    *)      err "Unknown option: $1"; exit 1 ;;
  esac
done

# Sanity checks
for cmd in python3 curl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    err "Required command not found: $cmd"
    exit 1
  fi
done

if [[ -f "$SECRETS_FILE" ]]; then
  load_secrets
  if [[ -n "${GH_APP_ID:-}" ]]; then
    warn "GitHub App already configured (GH_APP_ID=${GH_APP_ID})"
    read -rp "Overwrite? [y/N] " confirm
    [[ "$confirm" =~ ^[yY] ]] || exit 0
  fi
fi

# ── Build manifest JSON ──────────────────────────────────────────────
CALLBACK_URL="http://localhost:${CALLBACK_PORT}/callback"

MANIFEST=$(cat <<MANIFEST_EOF
{
  "name": "${APP_NAME}",
  "url": "https://github.com/minsley/lobmob",
  "hook_attributes": {"url": "https://example.com/unused", "active": false},
  "redirect_url": "${CALLBACK_URL}",
  "public": false,
  "default_permissions": {
    "contents": "write",
    "pull_requests": "write",
    "metadata": "read"
  },
  "default_events": []
}
MANIFEST_EOF
)

# ── Start callback server ────────────────────────────────────────────
CODE_FILE=$(mktemp)
rm -f "$CODE_FILE"

# Export org so the Python server can read it
export GITHUB_ORG

log "Starting callback server on port ${CALLBACK_PORT}..."

python3 - "$CALLBACK_PORT" "$CODE_FILE" "$MANIFEST" <<'PYEOF' &
import http.server
import sys
import os
import urllib.parse
import json

port = int(sys.argv[1])
code_file = sys.argv[2]
manifest = sys.argv[3]

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # suppress default logging

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)

        if parsed.path == "/":
            # Serve auto-submitting form
            if os.environ.get("GITHUB_ORG"):
                action = f"https://github.com/organizations/{os.environ['GITHUB_ORG']}/settings/apps/new"
            else:
                action = "https://github.com/settings/apps/new"

            manifest_escaped = json.dumps(manifest)  # double-encode for HTML attribute
            html = f"""<!DOCTYPE html>
<html><body>
<p>Redirecting to GitHub to create the app...</p>
<form id="f" method="post" action="{action}">
  <input type="hidden" name="manifest" value='{manifest}'>
</form>
<script>document.getElementById('f').submit();</script>
</body></html>"""
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(html.encode())

        elif parsed.path == "/callback":
            params = urllib.parse.parse_qs(parsed.query)
            code = params.get("code", [""])[0]
            if code:
                with open(code_file, "w") as f:
                    f.write(code)
                html = "<html><body><p>GitHub App created! You can close this tab.</p></body></html>"
            else:
                html = "<html><body><p>Error: no code received.</p></body></html>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(html.encode())
            if code:
                # Shutdown after successful callback
                import threading
                threading.Thread(target=self.server.shutdown).start()
        else:
            self.send_response(404)
            self.end_headers()

server = http.server.HTTPServer(("127.0.0.1", port), Handler)
server.serve_forever()
PYEOF
SERVER_PID=$!

# Wait for server to start
sleep 1
if ! kill -0 "$SERVER_PID" 2>/dev/null; then
  err "Callback server failed to start (port $CALLBACK_PORT in use?)"
  exit 1
fi

cleanup_server() {
  kill "$SERVER_PID" 2>/dev/null
  wait "$SERVER_PID" 2>/dev/null || true
  rm -f "$CODE_FILE"
}
trap cleanup_server EXIT

# ── Open browser ─────────────────────────────────────────────────────
log "Opening browser to create GitHub App '${APP_NAME}'..."
if command -v open &>/dev/null; then
  open "http://localhost:${CALLBACK_PORT}/"
elif command -v xdg-open &>/dev/null; then
  xdg-open "http://localhost:${CALLBACK_PORT}/"
else
  log "Open this URL in your browser: http://localhost:${CALLBACK_PORT}/"
fi

# ── Wait for callback ────────────────────────────────────────────────
log "Waiting for GitHub callback (up to 5 minutes)..."
TIMEOUT=300
ELAPSED=0
while [[ ! -f "$CODE_FILE" ]] && [[ "$ELAPSED" -lt "$TIMEOUT" ]]; do
  sleep 2
  ELAPSED=$((ELAPSED + 2))
done

if [[ ! -f "$CODE_FILE" ]]; then
  err "Timed out waiting for GitHub callback"
  exit 1
fi

CODE=$(cat "$CODE_FILE")
log "Received code from GitHub"

# ── Exchange code for credentials ────────────────────────────────────
log "Exchanging code for app credentials..."
RESPONSE=$(curl -sf -X POST \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/app-manifests/${CODE}/conversions")

if [[ -z "$RESPONSE" ]]; then
  err "Failed to exchange code — empty response from GitHub"
  exit 1
fi

# Parse response
APP_ID=$(echo "$RESPONSE" | jq -r '.id // empty')
APP_SLUG=$(echo "$RESPONSE" | jq -r '.slug // empty')
PEM_RAW=$(echo "$RESPONSE" | jq -r '.pem // empty')
CLIENT_ID=$(echo "$RESPONSE" | jq -r '.client_id // empty')

if [[ -z "$APP_ID" || -z "$PEM_RAW" ]]; then
  err "Failed to parse GitHub response:"
  echo "$RESPONSE" | jq . 2>/dev/null || echo "$RESPONSE"
  exit 1
fi

log "Created GitHub App: ${APP_SLUG} (ID: ${APP_ID})"

# Base64 encode PEM
PEM_B64=$(echo "$PEM_RAW" | base64)

# ── Write to secrets file ────────────────────────────────────────────
log "Writing credentials to ${SECRETS_FILE}..."

# Create secrets file if it doesn't exist
if [[ ! -f "$SECRETS_FILE" ]]; then
  cp "$PROJECT_DIR/secrets.env.example" "$SECRETS_FILE"
fi

# Update or append each credential
update_secret() {
  local key="$1" value="$2"
  if grep -q "^${key}=" "$SECRETS_FILE"; then
    portable_sed_i "s|^${key}=.*|${key}=${value}|" "$SECRETS_FILE"
  else
    echo "${key}=${value}" >> "$SECRETS_FILE"
  fi
}

update_secret "GH_APP_ID" "$APP_ID"
update_secret "GH_APP_PEM" "$PEM_B64"
# GH_APP_INSTALL_ID will be filled after installation
update_secret "GH_APP_INSTALL_ID" ""

log "Credentials saved to $SECRETS_FILE"

# ── Guide app installation ───────────────────────────────────────────
echo ""
log "Next step: install the app on your repositories."
log "The app needs access to your vault repo (and any project repos lobsters will work on)."
echo ""

INSTALL_URL="https://github.com/apps/${APP_SLUG}/installations/new"
log "Opening installation page..."
if command -v open &>/dev/null; then
  open "$INSTALL_URL"
elif command -v xdg-open &>/dev/null; then
  xdg-open "$INSTALL_URL"
else
  log "Open this URL: $INSTALL_URL"
fi

# ── Poll for installation ────────────────────────────────────────────
log "Waiting for app installation (up to 5 minutes)..."

# Generate JWT for polling
JWT_SCRIPT=$(cat <<'JWTEOF'
import jwt, time, sys, base64
app_id = sys.argv[1]
pem_b64 = sys.argv[2]
pem = base64.b64decode(pem_b64)
now = int(time.time())
payload = {"iat": now - 60, "exp": now + 540, "iss": app_id}
print(jwt.encode(payload, pem, algorithm="RS256"))
JWTEOF
)

poll_jwt() {
  python3 -c "$JWT_SCRIPT" "$APP_ID" "$PEM_B64" 2>/dev/null
}

INSTALL_ID=""
ELAPSED=0
while [[ -z "$INSTALL_ID" ]] && [[ "$ELAPSED" -lt "$TIMEOUT" ]]; do
  sleep 3
  ELAPSED=$((ELAPSED + 3))
  JWT_TOKEN=$(poll_jwt) || continue

  INSTALLS=$(curl -sf \
    -H "Authorization: Bearer $JWT_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app/installations" 2>/dev/null) || continue

  INSTALL_ID=$(echo "$INSTALLS" | jq -r '.[0].id // empty' 2>/dev/null)
done

if [[ -z "$INSTALL_ID" ]]; then
  warn "Timed out waiting for installation."
  warn "After installing the app, set GH_APP_INSTALL_ID manually in $SECRETS_FILE"
  warn "Find it at: https://github.com/settings/apps/${APP_SLUG}/installations"
  exit 0
fi

update_secret "GH_APP_INSTALL_ID" "$INSTALL_ID"
log "Installation ID: ${INSTALL_ID} — saved to $SECRETS_FILE"

echo ""
log "GitHub App setup complete!"
log "  App:          ${APP_SLUG} (ID: ${APP_ID})"
log "  Installation: ${INSTALL_ID}"
log "  Secrets:      ${SECRETS_FILE}"
echo ""
log "Next steps:"
log "  1. Push broker secrets:  lobmob secrets push-broker"
log "  2. Restart lobwife:      lobmob restart lobwife"
log "  3. Verify:               lobmob verify lobwife"
