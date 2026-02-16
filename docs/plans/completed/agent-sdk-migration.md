---
status: completed
tags: [infrastructure, migration]
maturity: implementation
created: 2026-02-12
updated: 2026-02-14
---
# Agent SDK Migration Plan

> Migrate lobmob from OpenClaw to Claude Agent SDK + discord.py + DOKS.
> Reference: [agent-sdk-deep-dive.md](../../research/agent-sdk-deep-dive.md)

## Status: MIGRATION COMPLETE (2026-02-12)

Phases 0-4 are **done**. Phase 5 partially complete. The system is running on DOKS in production.

### What was completed:
- **Phase 0 (Foundation)**: Project structure, Dockerfiles, docker-compose — DONE
- **Phase 1 (Lobboss Agent Core)**: discord.py bot, Agent SDK integration, MCP tools, hooks, health checks — DONE
- **Phase 2 (Lobster Agent Core)**: run_task.py, prompts, vault helper, credential scoping — DONE
- **Phase 3 (DOKS Infrastructure)**: Terraform DOKS, k8s manifests (Kustomize), CronJobs, CI/CD, deployed to dev — DONE
- **Phase 4 (Production Cutover)**: Prod DOKS cluster, lobboss deployed, validation pending — DONE
  - Task 4.4 (decommission): Code removed, TF state cleaned. Old DO resources still exist — destroy manually.
- **Phase 5 (Cleanup)**: CLI rewritten (5.1 DONE), docs updated (5.2 DONE), MEMORY updated (5.4 DONE)
  - Web UI ported to k8s (not in original plan): lobboss dashboard + lobster sidecar
  - 50+ files of Droplet/WireGuard/OpenClaw code removed (~3500 lines)
  - Terraform cleaned: DOKS-only, no more count gates, DO Project includes DOKS cluster

### Remaining work (Phase 5):
- **5.3**: Build reference task suite (10-20 test tasks for regression testing)
- Rewrite `task-manager.sh` and `status-reporter.sh` in Python (deferred, currently bash CronJobs)
- Manually destroy old Droplet/firewall/reserved IP resources in DO console
- Session rotation (1.10) not yet implemented — lobboss runs indefinitely, may need rotation for long sessions

## Branch Strategy

All work on branch `agent-sdk-migration` off `develop`. Merged to `main` on 2026-02-12.

## Stack

- **Agent framework**: Claude Agent SDK (Python)
- **Discord**: discord.py
- **Containers**: Docker (local dev), DOKS (production)
- **IaC**: Terraform (DOKS cluster, node pools, registry)
- **Cron scripts**: Keep existing bash, run as k8s CronJobs
- **Registry**: GHCR (default) or DO Container Registry
- **Vault**: Unchanged (git repo at /opt/vault, PVC in DOKS)

## Conventions

- Each task below is atomic — one person or agent can complete it independently
- Tasks have explicit inputs (what must exist before starting) and outputs (what must exist when done)
- `[H]` = requires human judgment or access (secrets, DNS, accounts)
- `[A]` = suitable for an AI agent (code writing, scripting, testing)
- `[HA]` = human decision + agent execution

---

## Phase 0: Foundation

Set up the branch, project structure, and development tooling.

### 0.1 Create migration branch and project structure [A]

**Input**: Current `develop` branch
**Output**: Branch `agent-sdk-migration` with new directory skeleton

- Create branch `agent-sdk-migration` from `develop`
- Create directory structure:
  ```
  containers/
    base/Dockerfile
    lobboss/Dockerfile
    lobster/Dockerfile
    .dockerignore
  src/
    lobboss/
      __init__.py
      bot.py           # discord.py bot entrypoint
      agent.py          # Agent SDK integration
      mcp_tools.py      # Custom MCP tools
      config.py         # Configuration loading
    lobster/
      __init__.py
      run_task.py       # Lobster entrypoint
      agent.py          # Agent SDK integration
      config.py
    common/
      __init__.py
      vault.py          # Vault git operations
  docker-compose.yml
  docker-compose.dev.yml
  requirements.txt
  ```
- Create `requirements.txt` with initial dependencies: `claude-agent-sdk`, `discord.py`, `anthropic`, `pyyaml`
- Create `.dockerignore` excluding `.git`, `secrets*.env`, `*.tfstate`, `infra/`
- Commit skeleton

### 0.2 Create base Dockerfile [A]

**Input**: Task 0.1 complete
**Output**: `containers/base/Dockerfile` that builds and passes a smoke test

- Base image: `python:3.12-slim`
- Install system packages: `git`, `curl`, `jq`, `openssh-client`
- Install Node.js 22 (required by Agent SDK runtime)
- Install Python dependencies from `requirements.txt`
- Install `@anthropic-ai/claude-code` npm package globally (Agent SDK dependency)
- Set working directory to `/app`
- Smoke test: `docker build -t lobmob-base containers/base/ && docker run --rm lobmob-base python -c "import claude_agent_sdk; print('ok')"`

### 0.3 Create lobboss Dockerfile [A]

**Input**: Task 0.2 complete
**Output**: `containers/lobboss/Dockerfile` that builds successfully

- `FROM lobmob-base`
- Copy `src/lobboss/` to `/app/lobboss/`
- Copy `src/common/` to `/app/common/`
- Copy `skills/lobboss/` to `/app/skills/`
- Copy bash cron scripts from `scripts/server/` that lobboss needs: `lobmob-task-manager.sh`, `lobmob-watchdog.sh`, `lobmob-review-prs.sh`, `lobmob-status-reporter.sh`, `lobmob-pool-manager.sh`, `lobmob-gh-token.sh`, `lobmob-flush-logs.sh`, `lobmob-fleet-status.sh`, `lobmob-cleanup.sh`, `lobmob-log.sh`
- Install `doctl` and `gh` CLI (needed by cron scripts)
- Entrypoint: `python -m lobboss.bot`
- Build test: `docker build -t lobmob-lobboss containers/lobboss/`

### 0.4 Create lobster Dockerfile [A]

**Input**: Task 0.2 complete
**Output**: `containers/lobster/Dockerfile` that builds successfully

- `FROM lobmob-base`
- Copy `src/lobster/` to `/app/lobster/`
- Copy `src/common/` to `/app/common/`
- Copy `skills/lobster/` to `/app/skills/`
- Install `gh` CLI (needed for PR creation)
- Entrypoint: `python -m lobster.run_task`
- Build test: `docker build -t lobmob-lobster containers/lobster/`

### 0.5 Create docker-compose for local dev [A]

**Input**: Tasks 0.3, 0.4 complete
**Output**: `docker-compose.yml` and `docker-compose.dev.yml` that start lobboss locally

- `docker-compose.yml`: lobboss service with env_file, volume mounts for skills/ and vault
- `docker-compose.dev.yml`: override with bind mounts for `src/` (live code reload), lobster service in `testing` profile
- Volumes: `./skills/lobboss:/app/skills:ro`, `./vault-dev:/opt/vault`, `./src/lobboss:/app/lobboss:ro`
- Environment: `LOBMOB_ENV`, `DISCORD_TOKEN`, `ANTHROPIC_API_KEY` from env_file
- Verify: `docker-compose -f docker-compose.yml -f docker-compose.dev.yml config` validates

---

## Phase 1: Lobboss Agent Core

Build the discord.py bot and Agent SDK integration. Test locally.

### 1.1 Build discord.py bot skeleton [A]

**Input**: Phase 0 complete
**Output**: `src/lobboss/bot.py` — a running Discord bot that connects and logs messages

- Import discord.py, create `Bot` with intents (message_content, guilds, reactions)
- `on_ready` handler: log connected guilds and channels
- `on_message` handler: log messages from configured channels (#task-queue, #swarm-control), ignore own messages, ignore other channels
- Channel allowlist from config (env vars or config file)
- Message deduplication: track processed message IDs in a set (bounded, e.g., last 1000)
- Run with: `DISCORD_TOKEN=... python -m lobboss.bot`
- Test: bot appears online in Discord, logs messages from dev channels, ignores others

### 1.2 Build Agent SDK integration [A]

**Input**: Task 1.1 complete
**Output**: `src/lobboss/agent.py` — wrapper that sends a prompt to the Agent SDK and returns the response

- Create `LobbossAgent` class wrapping `ClaudeSDKClient`
- Configuration: model (default `sonnet`), system prompt (loaded from file), allowed tools, skill sources
- `async def query(prompt: str, session_id: str = None) -> AsyncIterator[Message]` — sends prompt, streams responses
- Session management: dict mapping Discord thread ID → Agent SDK session ID. New thread = new session. Reply in thread = resume session.
- Load system prompt from `openclaw/lobboss/AGENTS.md` content (the persona parts, not OpenClaw metadata)
- Load skills via `setting_sources` pointing to `/app/skills/`
- Test standalone: `python -c "from lobboss.agent import LobbossAgent; ..."` with a simple prompt, verify Agent SDK responds

### 1.3 Wire bot to Agent SDK [A]

**Input**: Tasks 1.1, 1.2 complete
**Output**: Bot receives Discord messages and responds via Agent SDK

- `on_message` handler: if message is in #task-queue or #swarm-control:
  1. Check dedup (skip if already processed)
  2. Determine session_id from thread (create thread if top-level message in #task-queue)
  3. Call `LobbossAgent.query()` with message content + session_id
  4. Post response(s) to the thread
- Sequential processing: use an `asyncio.Queue` to serialize message handling (one at a time)
- Error handling: if Agent SDK fails, post error message to thread, log full traceback
- Test: send a message in dev #task-queue, verify bot creates thread and responds with coherent Agent SDK output

### 1.4 Build discord_post MCP tool [A]

**Input**: Task 1.3 complete
**Output**: `discord_post` MCP tool that the Agent SDK can call to post Discord messages

- In `src/lobboss/mcp_tools.py`, define `discord_post` tool:
  - Input: `channel_id` or `thread_id`, `content`, optional `message_id` (for edits)
  - Output: posted message ID
  - Implementation: call discord.py bot's channel/thread send method
- Need to pass the bot instance to the MCP server (dependency injection or module-level reference)
- Register with Agent SDK via `create_sdk_mcp_server()`
- Test: send a message that triggers the agent, verify the agent uses `discord_post` to respond in the right thread

### 1.5 Build spawn_lobster MCP tool (stub) [A]

**Input**: Task 1.4 complete
**Output**: `spawn_lobster` MCP tool with a stub implementation that logs but doesn't create real resources

- In `src/lobboss/mcp_tools.py`, define `spawn_lobster` tool:
  - Input: `task_id`, `lobster_type` (swe/qa/research), `workflow` (default/unity/web/etc.)
  - Output: job name, status
  - Implementation (stub): log the parameters, return a fake job name
- This gets replaced with real k8s Job creation in Phase 3
- Test: verify agent can call the tool and gets a response

### 1.6 Build lobster_status MCP tool (stub) [A]

**Input**: Task 1.4 complete
**Output**: `lobster_status` MCP tool with stub implementation

- Input: optional `task_id` or `job_name` filter
- Output: list of lobster statuses (stub: empty list or mock data)
- Gets replaced with real k8s API queries in Phase 3

### 1.7 Port lobboss system prompt [A]

**Input**: Task 1.2 complete
**Output**: System prompt file that captures the lobboss persona without OpenClaw-specific instructions

- Read `openclaw/lobboss/AGENTS.md` and `vault-seed/AGENTS.md` (and `vault-seed/040-fleet/lobboss-AGENTS.md`)
- Extract the persona, communication style, and behavioral rules
- Remove OpenClaw-specific references (gateway, openclaw CLI, session management)
- Add Agent SDK-specific context (available MCP tools, skill loading behavior)
- Write to `src/lobboss/system_prompt.md`
- Keep the CRITICAL RULES (single response, thread-only, no direct execution) — but now they're enforced by the bot layer + hooks, not just prose

### 1.8 Implement hooks for safety guardrails [A]

**Input**: Task 1.3 complete
**Output**: Hook definitions in lobboss agent config

- `PreToolUse(Bash)`: block dangerous commands (`rm -rf /`, `git push --force`, `shutdown`, etc.)
- `PostToolUse(discord_post)`: log all Discord posts to vault (020-logs/)
- `PreToolUse(spawn_lobster)`: validate task_id exists in vault, lobster_type is valid
- Define hooks in agent configuration, not in system prompt prose
- Test: trigger a dangerous command scenario, verify hook blocks it

### 1.9 Build structured logging and cost tracking [A]

**Input**: Task 1.3 complete
**Output**: `src/common/logging.py` — structured JSON logging for all agent activity

- Log every LLM call: model, token counts (input/output), latency, session_id, task_id
- Log every tool invocation: tool name, arguments (sanitized — strip secrets), return summary, duration
- Log task-level aggregates: total tokens, total cost (calculated from model pricing), total round-trips, outcome
- Cost calculation: maintain a pricing table (Opus: $5/$25 per M, Sonnet: $3/$15, Haiku: $0.80/$4). Compute cost per task.
- Write to stdout as JSON (captured by k8s pod logs, queryable with `kubectl logs | jq`)
- Optional: Langfuse integration via OpenTelemetry (add behind a feature flag, not required for Phase 1)
- Token budget support: configurable max tokens per task. Log warnings at 80%, errors at 95%.

### 1.10 Implement session rotation for lobboss [A]

**Input**: Tasks 1.2, 1.3, 2.3 complete
**Output**: Lobboss automatically rotates Agent SDK sessions to prevent context rot

- Track session age and estimated context usage per thread
- When a session hits 60% context capacity OR 2 hours age:
  1. Serialize active state to vault: open tasks, pending confirmations, thread-to-session map
  2. Close the old Agent SDK session
  3. Start a new session with a state summary injected as the first message
- State summary format: structured markdown with active threads, pending tasks, recent decisions
- Session-to-thread mapping persists in memory (or SQLite for crash resilience)
- Log rotation events with before/after context sizes

### 1.11 Add health checks for external dependencies [A]

**Input**: Task 1.3 complete
**Output**: Health check module used before task assignment and as k8s liveness probe

- `src/common/health.py`:
  - `check_anthropic()` — lightweight API call (e.g., count tokens on a short string)
  - `check_github()` — `gh api /rate_limit` or equivalent
  - `check_discord()` — bot.is_ready() and latency check
- Used in two places:
  1. Before `spawn_lobster` — if any dependency is down, skip assignment and log warning
  2. As HTTP endpoint for k8s liveness/readiness probes (add a minimal HTTP server or use discord.py's built-in)
- Circuit breaker pattern: after 3 consecutive failures on a dependency, stop attempting tasks for 5 minutes. Log escalation to Discord.

### 1.12 Local integration test: full lobboss flow [HA]

**Input**: All Phase 1 tasks complete
**Output**: Lobboss bot running locally via docker-compose, handling a complete interaction

- Start lobboss via `docker-compose up`
- In dev Discord #dev-task-queue: post a task request
- Verify: bot creates thread, proposes task, waits for "go", creates task file in vault, posts confirmation
- Verify: dedup works (re-sending same message doesn't produce duplicate responses)
- Verify: thread context persists (follow-up messages in thread maintain conversation)
- Verify: agent uses skills correctly (task-create skill is followed)
- Verify: structured logs show token counts and cost per interaction
- Verify: health checks pass and are logged
- Document any issues found, create follow-up tasks

---

## Phase 2: Lobster Agent Core

Build the ephemeral lobster agent. Test locally.

### 2.1 Build lobster run_task.py [A]

**Input**: Phase 0 complete (Dockerfile exists)
**Output**: `src/lobster/run_task.py` — CLI that reads a task file and executes it via Agent SDK

- Parse CLI args: `--task <task-id>`, `--type <swe|qa|research>`, `--vault-path <path>`, `--token-budget <max-tokens>`
- Load task file from vault: `<vault-path>/010-tasks/active/<task-id>.md`
- Parse YAML frontmatter to get task metadata (type, model, repo, etc.)
- Select model based on type: `opus` for swe, `sonnet` for qa/research
- Load appropriate skills based on type: `code-task` for swe, `verify-task` for qa, `task-execute` for research
- Build system prompt from lobster persona content
- **Token budget**: default 500K tokens for research/QA, 1M for SWE. At 80%, log warning. At 95%, force agent to commit partial work and exit.
- **Recovery**: on startup, check if a branch already exists for this task (previous failed attempt). If so, check it out and continue from last commit instead of starting fresh.
- **Early push**: create draft PR after first meaningful commit. Push after every logical unit. Don't accumulate unpushed work.
- Use structured logging from `src/common/logging.py` — all output as JSON to stdout
- Call `query()` with task description + skill instructions as prompt
- Exit with code 0 on success, 1 on failure
- Test: `python -m lobster.run_task --task test-task --type research --vault-path ./vault-dev`

### 2.2 Port lobster system prompts [A]

**Input**: Task 2.1 started
**Output**: System prompt files for each lobster type

- Read `openclaw/lobster/AGENTS.md`, `openclaw/lobster-swe/AGENTS.md`, `openclaw/lobster-qa/AGENTS.md`
- Extract persona, behavioral rules, model preferences
- Remove OpenClaw-specific references
- Write to `src/lobster/prompts/research.md`, `src/lobster/prompts/swe.md`, `src/lobster/prompts/qa.md`
- Include common instructions: vault location, git workflow, PR conventions, logging expectations

### 2.3 Build vault helper module [A]

**Input**: Phase 0 complete
**Output**: `src/common/vault.py` — shared vault operations used by both lobboss and lobster

- `pull_vault(path)` — `git -C <path> pull origin main`
- `commit_and_push(path, message, files)` — add, commit, push specific files
- `read_task(path, task_id)` — load and parse task markdown (frontmatter + body)
- `write_task(path, task_id, metadata, body)` — serialize and write task file
- `move_task(path, task_id, from_dir, to_dir)` — move between active/completed/failed
- Handle git conflicts gracefully (pull before push, retry once)
- Test with a local vault clone

### 2.4 Lobster credential scoping and safety hooks [A]

**Input**: Task 2.1 complete
**Output**: Lobster agents have minimal required permissions

- **GitHub token scoping**: lobster gets a token scoped to the target repo only, not org-wide. Write access to feature branches, read access to develop/main.
- **QA lobster restrictions**: verify-task type gets read-only repo access. Cannot push code, only read diffs and run tests. Output is structured verdict (pass/fail + reasons), not code changes.
- **Filesystem restrictions**: workspace and /tmp are writable. /app, /etc, secrets mounts are read-only.
- **Network policy** (k8s): lobster pods can reach only Anthropic API (api.anthropic.com), GitHub (github.com, api.github.com), and DNS. All other egress blocked.
- Hooks: `PreToolUse(Bash)` blocks `curl` to non-allowlisted domains, `rm -rf /`, `env` (prevents secret dumping), etc.

### 2.5 Local integration test: lobster executes a task [HA]

**Input**: Tasks 2.1, 2.2, 2.3, 2.4 complete
**Output**: Lobster container runs locally, reads a task from vault, produces work

- Create a test task file in `vault-dev/010-tasks/active/`
- Run: `docker-compose run lobster --task <test-task-id> --type research`
- Verify: lobster reads the task, executes it using Agent SDK, writes results to vault
- For SWE type: verify it creates a branch, makes commits, creates a draft PR early, pushes incrementally
- Verify: structured logs show token usage and cost
- Verify: recovery works — kill the container mid-task, restart, verify it picks up from last commit
- Document any issues found

---

## Phase 3: DOKS Infrastructure

Set up the Kubernetes cluster and deploy containers.

### 3.1 Terraform DOKS cluster [A]

**Input**: Phase 0 complete
**Output**: Terraform config that creates a DOKS cluster with two node pools

- New file `infra/doks.tf` (or extend `main.tf` with conditional resources)
- Resources:
  - `digitalocean_kubernetes_cluster.lobmob` — standard control plane (free), region from var
  - Node pool `lobboss` — 1x s-2vcpu-4gb, auto_scale=false (always-on)
  - Node pool `lobsters` — 0-5x s-2vcpu-4gb, auto_scale=true, min_nodes=0
  - `digitalocean_container_registry.lobmob` — if using DO registry (optional, can use GHCR)
- VPC: reuse existing `digitalocean_vpc.swarm` or create new
- Output: cluster ID, kubeconfig endpoint, node pool IDs
- Variables: `doks_enabled` (bool, default false), `doks_region`, `lobboss_node_size`, `lobster_node_size`, `lobster_max_nodes`
- Validate: `cd infra && terraform validate`

### 3.2 Kubernetes manifests: lobboss Deployment [A]

**Input**: Tasks 0.3, 3.1 complete
**Output**: k8s manifests that deploy lobboss as a Deployment

- Create `k8s/` directory in repo
- `k8s/namespace.yaml` — `lobmob` namespace
- `k8s/lobboss-deployment.yaml`:
  - 1 replica, `lobmob-lobboss` image
  - Resource requests: 512Mi memory, 500m CPU
  - Resource limits: 1.5Gi memory, 1 CPU
  - Volume mounts: vault PVC at `/opt/vault`, secrets as env vars
  - Liveness probe: check discord.py bot is connected
  - Node selector: `lobboss` node pool
- `k8s/lobboss-pvc.yaml` — PersistentVolumeClaim for vault (10Gi block storage)
- `k8s/secrets.yaml.template` — template for k8s Secret (not committed; actual secrets created via kubectl)
- Validate manifests: `kubectl apply --dry-run=client -f k8s/`

### 3.3 Kubernetes manifests: lobster Job template [A]

**Input**: Tasks 0.4, 3.1 complete
**Output**: k8s Job template that lobboss uses to spawn lobster pods

- `k8s/lobster-job-template.yaml` — Job spec:
  - `restartPolicy: Never`
  - `backoffLimit: 0` (no retries — if it fails, it fails)
  - `activeDeadlineSeconds: 7200` (2 hour hard timeout)
  - Image: `lobmob-lobster` (overridable for workflow-specific images)
  - Resource requests: 1Gi memory, 500m CPU
  - Resource limits: 3Gi memory, 1.5 CPU
  - Env: `TASK_ID`, `LOBSTER_TYPE`, `ANTHROPIC_API_KEY`, `GH_TOKEN` from secrets
  - Volume: vault clone (initContainer does `git clone`, main container works in it)
  - Node selector: `lobsters` node pool (triggers autoscaler)
  - Labels: `lobmob.io/task-id`, `lobmob.io/lobster-type`, `lobmob.io/workflow`
- Note: lobboss creates Jobs by templating this spec via Python `kubernetes` client, not `kubectl`

### 3.4 Kubernetes manifests: CronJobs [A]

**Input**: Tasks 0.3, 3.2 complete
**Output**: k8s CronJobs replacing system crontab

- `k8s/cronjobs.yaml` containing:
  - `task-manager` — every 5 min, runs `lobmob-task-manager.sh`
  - `watchdog` — every 5 min, runs `lobmob-watchdog.sh`
  - `review-prs` — every 2 min, runs `lobmob-review-prs.sh`
  - `status-reporter` — every 30 min, runs `lobmob-status-reporter.sh`
  - `gh-token-refresh` — every 45 min, runs `lobmob-gh-token.sh`
  - `flush-logs` — every 30 min, runs `lobmob-flush-logs.sh`
- All run in the lobboss container image (has the scripts + tools)
- Mount same vault PVC as lobboss Deployment
- Same secrets as lobboss
- `concurrencyPolicy: Forbid` (don't run if previous still active)
- Schedule on lobboss node pool (always-on)

### 3.5 Implement real spawn_lobster MCP tool [A]

**Input**: Tasks 1.5 (stub), 3.3 (Job template) complete
**Output**: `spawn_lobster` tool creates real k8s Jobs

- Replace stub in `src/lobboss/mcp_tools.py`
- Use `kubernetes` Python client library
- Load Job template, patch with: task_id, lobster_type, workflow image, secrets
- Create Job in `lobmob` namespace
- Return job name and initial pod status
- Add `kubernetes` to `requirements.txt`
- Test: call the tool, verify Job appears in cluster (`kubectl get jobs -n lobmob`)

### 3.6 Implement real lobster_status MCP tool [A]

**Input**: Tasks 1.6 (stub), 3.1 complete
**Output**: `lobster_status` tool queries real k8s pod status

- Replace stub in `src/lobboss/mcp_tools.py`
- Query k8s API for Jobs/Pods with `lobmob.io/task-id` label
- Return: job name, status (running/succeeded/failed), pod phase, age, last log lines
- Test: with a running lobster Job, verify status is returned correctly

### 3.7 Adapt cron scripts for container/k8s context [A]

**Input**: Task 3.4 complete
**Output**: Cron scripts work inside a container with k8s

- Audit each cron script for assumptions that need to change:
  - `doctl compute droplet list` → may need to query k8s Jobs instead (or keep doctl for Droplet-based lobsters during transition)
  - SSH commands to lobsters → may need to use `kubectl exec` or `kubectl logs` instead
  - File paths: ensure `/opt/vault` and script locations are correct in container context
  - Discord posting: scripts currently use bot API directly — this should continue to work
- **Do not rewrite** — make minimal changes (env vars, paths) to run in container
- Create a wrapper script or env setup that each CronJob sources before running the actual script
- Test each script in the container: `docker run --rm lobmob-lobboss bash -c ". /app/env.sh && /app/scripts/lobmob-task-manager.sh"`

### 3.8 Container image CI/CD [HA]

**Input**: Phase 0 Dockerfiles exist
**Output**: GitHub Actions workflow that builds and pushes images on merge

- `.github/workflows/build-images.yml`:
  - Trigger: push to `develop` or `main` (or manual dispatch)
  - Steps: checkout, login to GHCR, build base → lobboss → lobster, push with commit SHA + branch tag
  - Cache: Docker layer caching via `actions/cache` or BuildKit
- Tag strategy: `ghcr.io/minsley/lobmob-lobboss:develop-<sha>`, `ghcr.io/minsley/lobmob-lobboss:latest`
- Test: merge a change, verify images appear in GHCR

### 3.9 Deploy to dev DOKS cluster [H]

**Input**: All Phase 3 tasks complete, Phase 1 and 2 tested locally
**Output**: lobboss running on DOKS dev cluster, connected to dev Discord channels

- `cd infra && terraform workspace select dev && terraform apply -var-file=dev.tfvars`
- Configure kubectl: `doctl kubernetes cluster kubeconfig save lobmob-dev`
- Create k8s secrets: `kubectl create secret generic lobmob-secrets -n lobmob --from-env-file=secrets-dev.env`
- Apply manifests: `kubectl apply -f k8s/`
- Verify lobboss pod starts and connects to Discord
- Verify CronJobs run on schedule
- Note: lobster Jobs won't work yet until the lobster image is pushed and GHCR auth is configured on the cluster

### 3.10 End-to-end test on dev DOKS [H]

**Input**: Task 3.9 complete
**Output**: Full task lifecycle works on DOKS

- Post a task request in dev Discord #dev-task-queue
- Verify: lobboss creates thread, proposes task, waits for "go"
- Approve the task with "go"
- Verify: lobboss creates task file in vault, assigns to a lobster
- Verify: lobster Job is created, pod starts, agent executes task
- Verify: lobster creates PR, updates vault, pod exits
- Verify: CronJob (review-prs or lobboss) detects the PR
- Document any issues, create follow-up tasks

---

## Phase 4: Production Cutover

Migrate production from OpenClaw on Droplets to Agent SDK on DOKS.

### 4.1 Production DOKS cluster [H]

**Input**: Phase 3 tested on dev
**Output**: Production DOKS cluster exists (empty, no workload yet)

- `cd infra && terraform workspace select default && terraform apply -var-file=prod.tfvars`
- Configure kubectl for prod cluster
- Create k8s secrets from `secrets.env`
- Do NOT apply workload manifests yet — just the cluster

### 4.2 Deploy lobboss to prod DOKS [H]

**Input**: Task 4.1 complete, Phase 3 dev testing passed
**Output**: Production lobboss running on DOKS, connected to prod Discord

- Apply k8s manifests with prod image tags
- Verify lobboss connects to prod Discord (#task-queue, #swarm-control, #swarm-logs)
- Verify CronJobs run
- Keep old lobboss droplet running (do NOT destroy yet) — it can be the rollback

### 4.3 Validate prod: run a real task [H]

**Input**: Task 4.2 complete
**Output**: One complete task lifecycle in production

- Post a task in #task-queue
- Walk through the full lifecycle (proposal → approval → creation → assignment → execution → PR → review → completion)
- Confirm lobster pods autoscale, execute, and clean up
- Monitor pod logs, vault state, Discord threads

### 4.4 Decommission old infrastructure [H]

**Input**: Task 4.3 passes, production runs stable for ≥24 hours
**Output**: Old OpenClaw droplets destroyed, WireGuard config removed

- Destroy old lobboss droplet (keep reserved IP if still useful, or release it)
- Remove WireGuard configuration from Terraform
- Remove OpenClaw-related Terraform resources (if any remain)
- Archive `templates/cloud-init-lobboss.yaml` (move to `archive/` or delete)
- Archive `scripts/server/lobmob-spawn-lobster.sh` and `lobmob-provision.sh` (OpenClaw-specific)
- Remove OpenClaw npm dependency from any remaining config
- Update CLAUDE.md and MEMORY.md to reflect new architecture
- Update `docs/` Obsidian vault with new architecture docs

---

## Phase 5: Cleanup and Documentation

### 5.1 Update lobmob CLI for DOKS [A]

**Input**: Phase 4 complete
**Output**: `lobmob` CLI commands work with DOKS instead of Droplets

- `lobmob deploy` → applies Terraform (DOKS cluster) + k8s manifests
- `lobmob spawn --type swe` → creates a k8s Job (or triggers lobboss to do it)
- `lobmob status` → queries k8s for pod/job status
- `lobmob teardown` → drains and destroys lobster Jobs
- `lobmob ssh-lobboss` → `kubectl exec -it` into lobboss pod
- `lobmob logs` → `kubectl logs` for lobboss or lobster pods
- Keep backward compatibility where possible; add `--legacy` flag for old Droplet commands during transition

### 5.2 Update project documentation [A]

**Input**: Phase 4 complete
**Output**: All docs reflect the new architecture

- Update `CLAUDE.md` — new project structure, commands, architecture
- Update `docs/` Obsidian vault — architecture diagrams, deployment guide, troubleshooting
- Update `vault-seed/AGENTS.md` — coordinator persona for new system
- Archive OpenClaw-specific docs (don't delete, move to `docs/archive/`)
- Update `tests/` smoke tests for the new deployment model

### 5.3 Build reference task suite [A]

**Input**: Phase 4 complete (system works end-to-end)
**Output**: 10-20 reference tasks with known-good outcomes for regression testing

- Create `tests/reference-tasks/` directory
- Write 10-20 task files covering:
  - Simple research task (Sonnet, ~5 min, should produce a knowledge page)
  - Simple code task (Opus, ~15 min, should produce a PR with tests)
  - QA review task (Sonnet, ~10 min, should produce pass/fail verdict)
  - Edge cases: empty repo, failing tests, ambiguous requirements
- For each task, document expected outcomes: files created, PR structure, vault updates
- Write `tests/run-reference-suite.sh`:
  - Creates tasks in dev vault
  - Waits for completion (poll task status)
  - Checks outcomes against expected patterns (deterministic: did it compile? did tests pass? did PR get created?)
  - Reports pass/fail per task, aggregate success rate
- Target: 80%+ pass rate on the suite (not 100% — non-determinism is expected)
- Run this suite after any skill or prompt change before deploying to prod

### 5.4 Update MEMORY.md [A]

**Input**: Phase 4 complete
**Output**: Memory files reflect the new architecture, remove stale OpenClaw entries

- Remove OpenClaw configuration section
- Remove WireGuard gotchas (no longer relevant)
- Remove cloud-init gotchas (no longer relevant)
- Add DOKS operational notes
- Add container build/push workflow
- Update "Next Steps" section
- Keep total under 200 lines

---

## Dependency Graph

```
Phase 0 (foundation)
  0.1 ─→ 0.2 ─→ 0.3 ─→ 0.5
                  0.4 ─→ 0.5

Phase 1 (lobboss, depends on Phase 0)
  1.1 ─→ 1.3
  1.2 ─→ 1.3 ─→ 1.4 ─→ 1.5
              │        ─→ 1.6
              ├─→ 1.8
              ├─→ 1.9
              └─→ 1.11
  1.7 (parallel with 1.1-1.6)
  1.10 (depends on 1.2, 1.3, 2.3)
  1.12 (depends on all of Phase 1)

Phase 2 (lobster, depends on Phase 0)
  2.1 ─→ 2.4 ─→ 2.5
  2.2 ─→ 2.5
  2.3 ─→ 2.5

Phase 3 (DOKS, depends on Phase 0; Phases 1-2 can run in parallel)
  3.1 ─→ 3.2 ─→ 3.4 ─→ 3.7
       ─→ 3.3 ─→ 3.5
              ─→ 3.6
  3.8 (parallel with 3.1-3.7)
  3.9 (depends on all Phase 3 + Phase 1 + Phase 2)
  3.10 (depends on 3.9)

Phase 4 (prod, depends on Phase 3)
  4.1 ─→ 4.2 ─→ 4.3 ─→ 4.4

Phase 5 (cleanup, depends on Phase 4)
  5.1, 5.2, 5.3, 5.4 (parallel)
```

## Critical Path

The minimum serial path to production:

```
0.1 → 0.2 → 0.3 → 1.1 → 1.2 → 1.3 → 1.4 → 1.9 → 1.12 → 3.1 → 3.2 → 3.5 → 3.9 → 3.10 → 4.1 → 4.2 → 4.3
```

Phases 1 and 2 can run in parallel. Phase 3 infra (3.1) can start as soon as Phase 0 is done. The bottleneck is the lobboss agent integration (Phase 1) — that's the most complex new code.

## Risk Mitigation

| Risk | Mitigation |
|---|---|
| **Agent SDK cold start too slow** | Use streaming input mode for lobboss (keep warm). Lobsters accept cold start. |
| **Agent SDK subprocess instability** | Direct Anthropic API fallback is documented in research. Could swap agent.py without changing bot.py. |
| **DOKS node autoscaler too slow** | Pre-pull lobster images via DaemonSet. Accept 1-3 min cold start for new nodes. |
| **Skills don't load correctly** | Test in Phase 1.12 and 2.5. Skills are markdown — easy to iterate. |
| **Cron scripts break in container** | Minimal changes in 3.7. Each script tested individually. Rollback = old droplet still running. |
| **Vault PVC contention** | Only lobboss + CronJobs write to vault. Lobsters clone their own copy. No concurrent writes. |
| **Discord bot disconnects** | discord.py has built-in reconnection. k8s liveness probe restarts pod if stuck. |
| **API cost overrun** | Token budgets per task (1.9). Cost tracking in structured logs. Model routing (Haiku/Sonnet/Opus by complexity). Budget 5x estimates. |
| **Context rot on lobboss** | Session rotation every 2-4h or at 60% capacity (1.10). State serialized to vault before rotation. |
| **Lobster crash mid-task** | Recovery from last commit (2.1). Draft PR created early. Push after every logical unit. Idempotent task assignment. |
| **Prompt injection via task content** | Structured task format. QA lobsters read-only (2.4). Output schema enforcement. Manager validates before acting. |
| **Secret exfiltration** | Credential scoping (2.4). Network policy blocks egress except allowlisted hosts. Hooks block `env`, `curl` to unknown domains. |
| **Agent coordination conflicts** | Branch-per-task isolation. File-scope awareness in task assignment (future). Timeouts on all blocking operations. |
| **Anthropic API outage** | Health checks (1.11). Circuit breaker pauses new assignments. Workers marked `stalled` not `failed`. Backoff + retry. |
| **Skill/prompt regression** | Reference task suite (5.3). Run in dev after any change. 80%+ pass rate required for promotion. |
