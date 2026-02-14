# OpenClaw Setup

How OpenClaw is configured on lobboss and lobster nodes. This covers the runtime setup that happens after cloud-init and secret provisioning.

## Config Files on Each Node

| File | Purpose |
|---|---|
| `/root/.openclaw/openclaw.json` | Main OpenClaw config (gateway, agents, channels) |
| `/root/.openclaw/.env` | API keys (loaded by gateway automatically) |
| `/root/.openclaw/AGENTS.md` | Agent persona definition |
| `/root/.openclaw/skills/` | Skill directories (each with SKILL.md) |
| `/etc/lobmob/secrets.env` | Raw secrets pushed by lobboss |

## Setting Up a Node

### 1. Run Onboard

```bash
openclaw onboard --non-interactive --accept-risk --workspace /opt/vault
```

Creates `openclaw.json` with gateway, agent defaults, and workspace path. The gateway won't be reachable yet (that's expected — it logs an error but the config is written).

### 2. Create `.env`

```bash
source /etc/lobmob/secrets.env
echo "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY" > /root/.openclaw/.env
chmod 600 /root/.openclaw/.env
```

OpenClaw loads `.env` from `~/.openclaw/` automatically. Do not put API keys in `openclaw.json`.

### 3. Add Discord Channel

The `openclaw channels add --channel discord --token "..."` CLI command may fail with `Unknown channel: discord`. This is a known issue. Workaround: write the config directly into `openclaw.json` using `jq`:

```bash
source /etc/lobmob/secrets.env
jq --arg token "$DISCORD_BOT_TOKEN" \
  '.channels = { discord: { enabled: true, token: $token, groupPolicy: "allowlist" } }' \
  /root/.openclaw/openclaw.json > /tmp/oc.tmp && mv /tmp/oc.tmp /root/.openclaw/openclaw.json
```

### 4. Set Agent Model

```bash
jq '.agents.defaults.model = { primary: "anthropic/claude-sonnet-4-5" }' \
  /root/.openclaw/openclaw.json > /tmp/oc.tmp && mv /tmp/oc.tmp /root/.openclaw/openclaw.json
```

The model field must be an object `{ "primary": "..." }`, not a plain string.

### 5. Start the Gateway

```bash
source /root/.openclaw/.env
nohup ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY openclaw gateway --port 18789 > /tmp/openclaw-gateway.log 2>&1 &
```

Verify:
```bash
openclaw channels status
# Should show: Discord default: enabled, configured, running, bot:@lobmob
```

### 6. Trigger an Agent

```bash
source /etc/lobmob/secrets.env
ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY openclaw agent --agent main --message "Check for queued tasks..."
```

This runs synchronously and returns when the agent finishes.

## Setting Up the Watchdog Agent (Lobboss Only)

After the gateway is running on lobboss, set up the watchdog monitoring agent:

```bash
source /etc/lobmob/secrets.env

# Register watchdog agent (Haiku model for low cost)
ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY openclaw agents add watchdog \
  --workspace /opt/vault \
  --model "anthropic/claude-haiku-4-5" \
  --non-interactive

# Copy AGENTS.md (from vault distribution or SCP'd file)
cp /opt/vault/040-fleet/watchdog-AGENTS.md /root/.openclaw/agents/watchdog/agent/AGENTS.md 2>/dev/null || true

# Copy watchdog skill
mkdir -p /root/.openclaw/skills/check-progress
cp /opt/vault/040-fleet/watchdog-skills/check-progress/SKILL.md /root/.openclaw/skills/check-progress/SKILL.md 2>/dev/null || true

# Add cron job (every 5 minutes)
ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY openclaw cron add \
  --name progress-check \
  --every 5m \
  --agent watchdog \
  --message "Check on active lobsters and report progress"
```

Verify:
```bash
openclaw agents list    # Should show main + watchdog
openclaw cron list      # Should show progress-check job
```

## Lobboss vs Lobster Differences

| Aspect | Lobboss | Lobster |
|---|---|---|
| AGENTS.md | `openclaw/lobboss/AGENTS.md` | `openclaw/lobster/AGENTS.md` (name set at spawn) |
| Skills | `skills/manager/` | `skills/worker/` |
| Workspace | `/opt/vault` (writes to main) | `/opt/vault` (writes to branches, submits PRs) |
| Discord role | Assigns tasks in #swarm-control | Listens for assignments, posts results |
| Gateway persistence | systemd service (`openclaw-gateway`) | systemd service (`openclaw-gateway`) |

## Known Issues

### `gh auth setup-git` clobbers git identity
Running `gh auth setup-git` overwrites `~/.gitconfig`, erasing `user.name` and `user.email`. Always re-set git identity after this command. The cloud-init scripts already handle this.

### `openclaw channels add --channel discord` fails
Returns `Unknown channel: discord` even though discord is listed in `--help`. Write the channels config directly into `openclaw.json` as shown above.

### `openclaw onboard` may hang over SSH
The `openclaw onboard` command can hang or take very long when run over SSH ProxyJump. It usually succeeds in writing the config even if the connection drops. Check for `/root/.openclaw/openclaw.json` afterward.

### Agent model must be an object
Setting `agents.defaults.model` to a string like `"anthropic/claude-sonnet-4-5"` causes a validation error. It must be `{ "primary": "anthropic/claude-sonnet-4-5" }`.

### `config.json` vs `openclaw.json`
The spawn script writes `/root/.openclaw/config.json` (an older format with embedded secrets). The `openclaw onboard` command creates `openclaw.json` (current format). When both exist, `openclaw.json` takes precedence. The `config.json` can be safely removed after onboard.

## Automated Setup (Lobsters)

The spawn script (`lobmob-spawn-lobster`) now fully automates OpenClaw setup during provisioning:

1. Runs `openclaw onboard` to create `openclaw.json`
2. Creates `.env` with the API key
3. Patches `openclaw.json` with Discord channel config via `jq` (bypassing the broken CLI)
4. Writes a metadata-only `AGENTS.md`
5. Installs and starts `openclaw-gateway.service` via systemd

The gateway starts automatically after provisioning and restarts on failure (systemd `Restart=on-failure`). Logs go to `/var/log/openclaw-gateway.log`.

Manual steps from this page are only needed for troubleshooting or when re-configuring an existing node.

## Gateway systemd Service

Both lobboss and lobsters run the gateway via systemd:

```bash
# Check status
systemctl status openclaw-gateway

# View logs
tail -f /var/log/openclaw-gateway.log

# Restart after config changes
systemctl restart openclaw-gateway
```

The service file is at `/etc/systemd/system/openclaw-gateway.service`. It uses `EnvironmentFile=/root/.openclaw/.env` to load the API key at runtime.
