# Web UI

Lobboss runs a lightweight web server on port 8080 for OAuth callbacks and fleet management.

## Architecture

- **Server**: Single-file Node.js script at `/usr/local/bin/lobmob-web`
- **Port**: 8080 (HTTP)
- **Dependencies**: None (uses Node.js built-in `http` module)
- **Service**: `lobmob-web.service` (systemd, auto-restart on failure)
- **Logs**: `/var/log/lobmob-web.log`
- **Config**: `/etc/lobmob/web.env` (OAuth client credentials)

## Routes

| Path | Method | Description |
|---|---|---|
| `/` | GET | Status dashboard with fleet overview |
| `/health` | GET | JSON health check (`{"status":"ok","uptime":...}`) |
| `/oauth/digitalocean` | GET | Redirects to DO OAuth authorize page |
| `/oauth/digitalocean/callback` | GET | Receives OAuth code, exchanges for tokens |

## Management

```bash
# Check status
systemctl status lobmob-web

# View logs
tail -f /var/log/lobmob-web.log

# Restart
systemctl restart lobmob-web
```

## When Is It Started?

The web UI is only started if `/etc/lobmob/web.env` exists (i.e., DO OAuth is configured). This happens during `lobmob-provision` if `DO_OAUTH_CLIENT_ID` and `DO_OAUTH_CLIENT_SECRET` are in `secrets.env`.

## Firewall

Port 8080 is open on the lobboss firewall (`lobmob-lobboss-fw`). This is required for:
- OAuth callbacks (browser redirects from DigitalOcean)
- Direct access to the status dashboard

## Future Expansion

The web UI is designed to be extended. Potential additions:
- Setup wizard for initial configuration
- Fleet monitoring dashboard (real-time lobster status)
- Task management (create, assign, monitor tasks)
- Log viewer (stream event logs from nodes)
- Token status page (expiry times, refresh status)

## HTTPS Upgrade Path

Currently HTTP-only (no domain needed). To add HTTPS:
1. Assign a domain to the reserved IP
2. Use Let's Encrypt with certbot for a free certificate
3. Update the web server to use `https.createServer()` with the cert
4. Update the DO OAuth callback URL to use `https://`
