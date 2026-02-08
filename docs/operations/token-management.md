# Token Management

How lobmob handles API tokens, including automatic renewal via GitHub App and DO OAuth.

## Token Overview

| Service | Method | Lifetime | Renewal |
|---|---|---|---|
| GitHub | App installation token | 1 hour | Automatic (JWT + PEM) |
| GitHub | Fine-grained PAT (fallback) | 30-90 days | Manual |
| DigitalOcean | OAuth access token | 30 days | Automatic (refresh token cron) |
| DigitalOcean | API token (fallback) | Until revoked | Manual |
| Discord | Bot token | Until revoked | Manual (regenerate in dev portal) |
| Anthropic | API key | Until revoked | Manual (regenerate in console) |

## GitHub App (Recommended)

GitHub Apps generate short-lived (1-hour) installation tokens from a PEM private key. No user interaction needed for renewal.

### Setup

1. Create a GitHub App at https://github.com/settings/apps/new
   - Name: `lobmob-fleet` (or any unique name)
   - Homepage URL: any valid URL
   - Permissions: Contents (rw), Pull requests (rw), Metadata (r)
   - Uncheck "Active" under Webhook (not needed)
2. After creation, note the **App ID** from the app settings page
3. Generate a private key (Downloads a `.pem` file)
4. Click "Install App" and install it on the vault repo only
5. Note the **Installation ID** from the URL: `github.com/settings/installations/<ID>`

### Configuration

Add to `secrets.env`:
```
GH_APP_ID=123456
GH_APP_INSTALL_ID=789012
GH_APP_PEM_B64=<base64 -w0 < your-app.pem>
```

The PEM is pushed to `/etc/lobmob/gh-app.pem` on lobboss during `lobmob provision-secrets`.

### How It Works

The `lobmob-gh-token` script on each node:
1. Reads the PEM and App ID from `/etc/lobmob/`
2. Creates a JWT (10-minute expiry) signed with RS256
3. POSTs to GitHub API to exchange JWT for an installation token
4. Returns the 1-hour token to stdout

Used as: `GH_TOKEN=$(lobmob-gh-token)` -- drop-in replacement for a PAT.

Both `lobmob-provision` and `lobmob-spawn-lobster` try the App token first, falling back to the `GH_TOKEN` PAT if the App isn't configured.

## DigitalOcean OAuth

DO OAuth tokens auto-renew via a refresh token. Requires one-time browser authorization.

### Setup

1. Create an OAuth App at https://cloud.digitalocean.com/account/api/applications
   - Name: `lobmob-fleet`
   - Callback URL: `http://<lobboss-reserved-ip>:8080/oauth/digitalocean/callback`
2. Note the **Client ID** and **Client Secret**

### Configuration

Add to `secrets.env`:
```
DO_OAUTH_CLIENT_ID=abc123...
DO_OAUTH_CLIENT_SECRET=def456...
```

These are pushed to `/etc/lobmob/web.env` on lobboss during provisioning.

### Authorization Flow

1. Open `http://<lobboss-ip>:8080/oauth/digitalocean` in your browser
2. Authorize the app on DigitalOcean
3. Callback stores access + refresh tokens in `/etc/lobmob/secrets.env`

### Automatic Renewal

A cron job runs `/usr/local/bin/lobmob-refresh-do-token` every 25 days (tokens last 30 days). It uses the refresh token to get a new access token without user interaction.

## Fallback Behavior

All token integrations are backward-compatible:

- If `GH_APP_PEM_B64` is not in `secrets.env`, the system uses `GH_TOKEN` (PAT) directly
- If `web.env` doesn't exist, the web UI and DO OAuth refresh cron are not started
- `DO_TOKEN` (API token) is always used for doctl authentication and Terraform

## Token Rotation

### Rotate GitHub App PEM
1. Go to the App settings on GitHub
2. Generate a new private key
3. Update `GH_APP_PEM_B64` in `secrets.env`
4. Run `lobmob provision-secrets`

### Rotate DO OAuth
1. Visit `http://<lobboss-ip>:8080/oauth/digitalocean` to re-authorize
2. New tokens are stored automatically

### Rotate Discord Bot Token
1. Regenerate in the Discord Developer Portal
2. Update `DISCORD_BOT_TOKEN` in `secrets.env`
3. Run `lobmob provision-secrets`

### Rotate Anthropic API Key
1. Regenerate in the Anthropic Console
2. Update `ANTHROPIC_API_KEY` in `secrets.env`
3. Run `lobmob provision-secrets`
