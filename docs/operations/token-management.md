# Token Management

How lobmob handles API tokens, including automatic renewal via GitHub App and DO OAuth.

## Token Overview

| Service | Method | Lifetime | Renewal |
|---|---|---|---|
| GitHub | App installation token (via broker) | 1 hour | Automatic (lobwife broker) |
| DigitalOcean | OAuth access token | 30 days | Automatic (refresh token cron) |
| DigitalOcean | API token (fallback) | Until revoked | Manual |
| Discord | Bot token | Until revoked | Manual (regenerate in dev portal) |
| Anthropic | API key | Until revoked | Manual (regenerate in console) |

## GitHub App Token Broker

All GitHub operations use ephemeral tokens generated on-demand by the **lobwife token broker**. No static PAT is needed.

### How It Works

The broker runs as part of the lobwife daemon and generates short-lived (1-hour) GitHub App installation tokens:

1. **lobwife** holds the GitHub App PEM key and generates JWT-signed requests
2. Services request tokens from the broker via HTTP API
3. The `gh-lobwife` wrapper (installed as `/usr/local/bin/gh` in all containers) fetches a fresh token before every `gh` invocation
4. Git credential helper routes through the wrapper: `git config --global credential.https://github.com.helper '!/usr/local/bin/gh auth git-credential'`

### Two Token Paths

| Path | Endpoint | Scope | Used By |
|---|---|---|---|
| Task tokens | `POST /api/token` | Single repo (vault) | Lobsters (ephemeral workers) |
| Service tokens | `POST /api/v1/service-token` | All repos the App can access | lobboss, lobsigliere, init containers |

Task tokens require pre-registration by lobboss (`POST /api/register`). Service tokens require only a service name.

### Container Auth Flow

Each container follows the same pattern at startup:

1. Fetch an initial token from the broker (with retry loop for lobwife startup)
2. Configure git credential helper: `git config --global credential.https://github.com.helper '!/usr/local/bin/gh auth git-credential'`
3. The `gh-lobwife` wrapper handles all subsequent token refreshes transparently

**Important**: Do NOT use `gh auth setup-git` — it registers `gh-real` (the actual gh binary) instead of the wrapper, bypassing broker tokens.

### Token Audit

Check issued tokens:
```
GET /api/token/audit
```

Returns a log of all token issuances with service names, task IDs, and timestamps.

### Setup

1. Create a GitHub App at https://github.com/settings/apps/new
   - Name: `lobmob-fleet` (or any unique name)
   - Homepage URL: any valid URL
   - Permissions: Contents (rw), Pull requests (rw), Metadata (r)
   - Uncheck "Active" under Webhook (not needed)
2. After creation, note the **App ID** from the app settings page
3. Generate a private key (Downloads a `.pem` file)
4. Click "Install App" and install it on all lobmob repos (lobmob, vault, vault-dev)
5. Note the **Installation ID** from the URL: `github.com/settings/installations/<ID>`

### Configuration

Add to `secrets.env`:
```
GH_APP_ID=123456
GH_APP_INSTALL_ID=789012
GH_APP_PEM_B64=<base64 -w0 < your-app.pem>
```

These are deployed to the `lobwife-secrets` k8s Secret (separate from `lobmob-secrets`). Only lobwife needs the PEM — all other services get tokens from the broker.

## DigitalOcean OAuth

DO OAuth tokens auto-renew via a refresh token. Requires one-time browser authorization.

### Setup

1. Create an OAuth App at https://cloud.digitalocean.com/account/api/applications
   - Name: `lobmob-fleet`
   - Callback URL: `http://<lobboss-ip>:8080/oauth/digitalocean/callback`
2. Note the **Client ID** and **Client Secret**

### Configuration

Add to `secrets.env`:
```
DO_OAUTH_CLIENT_ID=abc123...
DO_OAUTH_CLIENT_SECRET=def456...
```

### Authorization Flow

1. Open `http://<lobboss-ip>:8080/oauth/digitalocean` in your browser
2. Authorize the app on DigitalOcean
3. Callback stores access + refresh tokens

### Automatic Renewal

A cron job runs the DO token refresh every 25 days (tokens last 30 days). It uses the refresh token to get a new access token without user interaction.

## Token Rotation

### Rotate GitHub App PEM
1. Go to the App settings on GitHub
2. Generate a new private key
3. Update `GH_APP_PEM_B64` in `secrets.env`
4. Run `lobmob deploy` (or `lobmob apply` to just update secrets)
5. Restart lobwife: `kubectl -n lobmob rollout restart deployment/lobwife`

### Rotate Discord Bot Token
1. Regenerate in the Discord Developer Portal
2. Update `DISCORD_BOT_TOKEN` in `secrets.env`
3. Run `lobmob deploy` and restart deployments

### Rotate Anthropic API Key
1. Regenerate in the Anthropic Console
2. Update `ANTHROPIC_API_KEY` in `secrets.env`
3. Run `lobmob deploy` and restart deployments

### Rotate DO OAuth
1. Visit `http://<lobboss-ip>:8080/oauth/digitalocean` to re-authorize
2. New tokens are stored automatically
