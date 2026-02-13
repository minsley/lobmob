# Agent SDK Deep Dive: Replacing OpenClaw (Feb 2026)

## Context

This document expands on [agent-framework-comparison.md](agent-framework-comparison.md) and [openclaw-post-mortem.md](openclaw-post-mortem.md) with a comprehensive evaluation of every viable option for replacing OpenClaw in the lobmob swarm. The goal: find the right framework (or non-framework) for lobboss and lobsters.

## Requirements

What we need from any replacement:

1. **Reliable tool/skill execution** — when the agent is told to use a skill, it uses it. No lazy-load failures, no ignoring instructions.
2. **Discord integration** — receive messages, post in threads, handle reactions, dedup messages. Currently the #1 source of OpenClaw bugs.
3. **SSH orchestration** — lobboss coordinates lobsters over WireGuard/SSH. Must be able to run remote commands.
4. **Claude model selection** — Sonnet for research/QA, Opus for SWE tasks. Per-agent model override.
5. **Non-Claude capabilities via tools** — other models (image generation, specialized tasks) integrated as MCP tools, not as alternative agent brains.
6. **Session continuity** — conversation context should persist across messages in a Discord thread.
7. **Skill format compatibility** — existing SKILL.md files should work with minimal modification.
8. **Deterministic cron integration** — task-manager, pool-manager, watchdog scripts must continue working.
9. **Production stability** — framework shouldn't break on updates or require constant babysitting.
10. **Unified stack** — same framework for lobboss and lobsters, reducing maintenance burden.

## Frameworks Evaluated

### 1. Claude Agent SDK (Anthropic) — RECOMMENDED

The same agent loop and tools behind Claude Code, exposed as a library.

**Language**: Python (`pip install claude-agent-sdk`) and TypeScript (`npm install @anthropic-ai/claude-agent-sdk`). Both require Node.js on host (wraps Claude Code CLI as subprocess).

**Architecture**: Call `query()` with a prompt + options → spawns Claude Code subprocess → agent feedback loop (gather context → take action → verify → iterate) → streams messages back. No manual tool loop implementation needed.

For persistent connections, `ClaudeSDKClient` keeps the subprocess alive between messages. After ~12s cold start, subsequent queries respond in ~2-3s (streaming input mode).

**Built-in tools**: Read, Write, Edit, Bash, Glob, Grep, WebSearch, WebFetch, Task (subagents), AskUserQuestion. These are the same battle-tested implementations from Claude Code — file editing, context-aware search, sandboxed bash.

**Custom tools via MCP**: In-process MCP servers (no subprocess overhead) or external MCP servers via stdio/HTTP. Growing ecosystem of pre-built servers for GitHub, Postgres, Playwright, etc.

```python
# Example: custom SSH tool as in-process MCP server
@tool("ssh_exec", "Execute command on remote server", {"host": str, "command": str})
async def ssh_exec(args):
    result = await run_ssh(args["host"], args["command"])
    return {"content": [{"type": "text", "text": result}]}

server = create_sdk_mcp_server(name="remote-tools", tools=[ssh_exec])
```

**Subagents**: Define named agents with specific tools, prompts, and models. Parent spawns them via the `Task` tool. They run in isolated context and return results. Multiple can run in parallel. One level deep only (no sub-sub-agents).

```python
agents = {
    "code-reviewer": AgentDefinition(
        description="Reviews code for quality and security.",
        tools=["Read", "Glob", "Grep"],
        model="sonnet",
    ),
}
```

**Hooks**: PreToolUse, PostToolUse, Stop, SessionStart, SessionEnd, UserPromptSubmit. Use for audit logging, blocking dangerous commands, injecting validation. This replaces the guardrails we tried to put in AGENTS.md prose (which OpenClaw ignored).

**Skill/CLAUDE.md support**: Set `setting_sources=["project"]` to load `.claude/skills/SKILL.md` and `CLAUDE.md` files. Our existing skill format is directly compatible.

**Sessions**: Full persistence with resume/fork. Conversation state, files read, and analysis all survive across messages. Critical for Discord thread continuity.

**Model support**: Claude Opus, Sonnet, Haiku. Per-agent model override. Providers: Anthropic direct, Bedrock, Vertex, Azure. The agent brain is Claude-only — but non-Claude capabilities (image generation, embeddings, OCR, etc.) integrate cleanly as MCP tools. Claude reasons about *what* to do, then delegates specialized work to the appropriate model/API via tool calls. This "Claude as brain, other models as tools" pattern means the "Claude-only" limitation is a non-issue in practice.

**Discord**: Not native. Need a discord.py wrapper. This is actually an **advantage** — we get full control over deduplication, threading, sequential processing, and routing. All the things OpenClaw broke.

**Deployment**: Long-running process. ~1 GiB RAM, 5 GiB disk. Recommended patterns from docs: ephemeral (per-task), long-running (persistent listener), hybrid (resume from DB).

**Maturity**: Production-grade. Backed by Anthropic. Python SDK released Feb 10, 2026. Apple integrated it into Xcode 26.3. Active semver'd releases.

**Key risks**:
- ~12s cold start per `query()` — mitigated by streaming input mode (keep process warm)
- Wraps CLI as subprocess — one layer of indirection
- Node.js dependency even for Python SDK
- No native Discord — ~2-3 days to build a solid wrapper

### 2. Direct Anthropic API + discord.py (Custom)

Roll your own agent loop. Call the Messages API with `tools`, execute tool_use blocks, feed results back, repeat.

**What you implement yourself**:
- Agent feedback loop (`while stop_reason == "tool_use": execute, call API`)
- Tool implementations (bash execution, file read/write, git operations)
- Context management (conversation history, compaction when window fills)
- Session persistence
- Skill loading (parse SKILL.md, inject into system prompt)
- Error handling, retries, timeouts

**What you get**:
- Total control, zero framework abstractions
- First-class discord.py integration (no wrapper — Discord IS the app)
- Minimal dependencies (anthropic SDK + discord.py)
- No cold start penalty (direct API calls, no subprocess)
- Faster response times

**What you lose vs Agent SDK**:
- Battle-tested tool implementations (Edit is particularly complex to implement well)
- Context compaction (auto-summarization approaching context limit)
- Session resume/fork
- Hooks system
- Subagent coordination
- MCP server ecosystem
- Free improvements from Anthropic updates

**Effort estimate**: ~500+ lines of agent loop + tool execution vs ~100 lines of discord.py wrapper for the Agent SDK approach.

**Verdict**: Viable fallback. If the Agent SDK's subprocess overhead or cold start proves unacceptable, this is the escape hatch. But the SDK's built-in tools — especially Edit, Glob, Grep, and context compaction — are genuinely hard to replicate at the same quality.

### 3. Pydantic AI

Python agent framework from the Pydantic team. Type-safe, structured outputs, model-agnostic.

**Multi-model**: Best in class. Supports every major provider (OpenAI, Anthropic, Google, DeepSeek, Mistral, Ollama, etc.).

**Tools**: Python functions with type annotations. Pydantic validates I/O. Concurrent tool execution via asyncio. But **no built-in code tools** — you implement Bash, file read/write, git, etc. yourself.

**Multi-agent**: Delegation via tools, programmatic hand-off, or graph-based state machines. "Deep Agents" for autonomous planning + delegation.

**Durable execution**: Agents preserve progress across API failures and restarts. Relevant for long-running SWE tasks.

**Verdict**: Interesting but wrong tradeoff. The model-agnosticism doesn't help us — we want Claude as the agent brain and other models integrated as MCP tools, not swappable agent runtimes. The lack of built-in code tools hurts concretely (agents write code, run tests, create PRs). We'd spend weeks building what the Agent SDK ships for free.

### 4. LangGraph / LangChain

Models agent workflows as stateful directed graphs. Nodes = actions, edges = transitions.

**Strengths**: Complex conditional state machines with persistent state. Multi-model support.

**Weaknesses**: Heavy abstraction, steep learning curve, LangChain has a history of API churn. Tool calling has known reliability issues (nonexistent tools, schema mismatches).

**Verdict**: Overkill. Our orchestration is fundamentally sequential (receive message → read skill → call Claude → respond → maybe SSH). LangGraph's graph paradigm doesn't add value. Our state lives in the vault and Discord threads, not in LangGraph's state store.

### 5. CrewAI

Role-based multi-agent framework. Agents have roles, goals, backstories. Collaborate as "Crews."

**Critical problem**: Claude support via LiteLLM is unreliable. Community reports show breakages across multiple CrewAI versions (0.61.0, 0.63.6, 1.2.0). Default model is `gpt-4o-mini` — OpenAI-first design.

**Architecture mismatch**: CrewAI assumes in-process agents. Our lobsters are remote machines coordinated via SSH. The role/goal/backstory abstraction doesn't map to our AGENTS.md + SKILL.md model.

**Verdict**: Poor fit. Unreliable Claude support + wrong multi-agent paradigm.

### 6. AutoGen / Microsoft Agent Framework

AutoGen is in maintenance mode. Its successor "Microsoft Agent Framework" targets GA end of Q1 2026 (pre-GA as of Feb 2026).

**Verdict**: Bad timing. Building on AutoGen = building on legacy. Building on Agent Framework = building on pre-GA software. Azure/.NET orientation misaligns with our DO/bash/Node stack. Revisit when 1.0 GA ships and stabilizes.

### 7. OpenAI Agents SDK

OpenAI's multi-agent framework. Provider-agnostic via LiteLLM.

**Verdict**: Wrong ecosystem. Designed OpenAI-first. Claude support via LiteLLM adapter — structured outputs may not work, tracing requires OpenAI API key. If we were GPT-based this would be strong. For Claude, the Claude Agent SDK is the obvious pick.

## Comparison Matrix

| | Agent SDK | Custom API | Pydantic AI | LangGraph | CrewAI | AutoGen | OAI Agents |
|---|---|---|---|---|---|---|---|
| **Claude support** | Native (only) | Native (direct) | Yes (multi) | Yes (multi) | Buggy (LiteLLM) | Yes (multi) | Limited (LiteLLM) |
| **Built-in code tools** | Yes (full set) | No (BYO) | No (BYO) | No (BYO) | Custom system | Wrapper | Limited |
| **Discord** | Wrapper needed | First-class | Wrapper needed | Wrapper needed | Wrapper needed | Wrapper needed | Wrapper needed |
| **Multi-agent** | Subagents + Teams | BYO | Delegation + graphs | Graph-based | Crews + Flows | Async messaging | Handoffs |
| **Session mgmt** | Built-in | BYO | Durable execution | Persistent state | Flow state | Session-based | Session memory |
| **Skill compat** | Direct (SKILL.md) | Manual injection | Manual injection | Manual injection | Manual injection | Manual injection | Manual injection |
| **Maturity** | Production | N/A | Active | Mature | Buggy | Pre-GA | Active |
| **Learning curve** | Low | None (more code) | Low-medium | High | Medium | Medium | Low-medium |
| **Framework risk** | Low (Anthropic) | None | Low (Pydantic) | Medium (churn) | Medium (LiteLLM) | High (transition) | Low (OpenAI) |
| **Cold start** | ~12s (mitigable) | None | None | None | None | None | None |

## Architecture: Agent SDK + discord.py

Unified approach — both lobboss and lobsters on the Claude Agent SDK. Two deployment options (same container images work for both):

### Option A: DOKS (Kubernetes) — RECOMMENDED

```
┌─────────────────────────────────────────────────────────┐
│  DOKS Cluster (free control plane)                      │
│                                                         │
│  Always-on node pool (1x s-2vcpu-4gb, $24/mo)          │
│  ┌───────────────────────────────────────────────────┐  │
│  │                                                   │  │
│  │  lobboss Deployment (1 replica)                   │  │
│  │  ┌──────────────┐  ┌──────────────────────────┐  │  │
│  │  │ discord.py   │──│ Claude Agent SDK          │  │  │
│  │  │ bot layer    │  │ - Built-in tools          │  │  │
│  │  │ - dedup      │  │ - MCP: k8s_job_create     │  │  │
│  │  │ - threading  │  │ - MCP: discord_post       │  │  │
│  │  │ - routing    │  │ - MCP: external APIs      │  │  │
│  │  │ - sequential │  │ - Skills (SKILL.md)       │  │  │
│  │  └──────────────┘  └──────────────────────────┘  │  │
│  │                                                   │  │
│  │  CronJobs: task-mgr, pool-mgr, watchdog          │  │
│  │  PVC: /opt/vault (block storage)                  │  │
│  │                                                   │  │
│  └───────────────────────────────────────────────────┘  │
│                                                         │
│  Autoscaling worker node pool (0-N nodes, scale-to-0)   │
│  ┌───────────────────────────────────────────────────┐  │
│  │                                                   │  │
│  │  lobster Jobs (ephemeral, on-demand)              │  │
│  │  ┌─────────────────────────────────────────────┐  │  │
│  │  │ lobmob-lobster-swe (Opus, code tasks)       │  │  │
│  │  │ lobmob-lobster-qa (Sonnet, verification)    │  │  │
│  │  │ lobmob-lobster-unity (Unity Editor + SDK)   │  │  │
│  │  │ lobmob-lobster-web (browsers, Node.js)      │  │  │
│  │  │ ...any workflow-specific image               │  │  │
│  │  └─────────────────────────────────────────────┘  │  │
│  │                                                   │  │
│  │  Pod networking (no WireGuard needed)             │  │
│  │  Nodes scale down to 0 when no Jobs pending       │  │
│  │                                                   │  │
│  └───────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

Key differences from Droplets:
- **No WireGuard** — pods communicate natively via k8s networking
- **No SSH provisioning** — secrets injected via k8s Secrets, images pre-built
- **No pool-manager** — k8s autoscaler handles node lifecycle
- **No cloud-init** — everything is in the container image
- **lobboss creates Jobs** via k8s API instead of `doctl compute droplet create` + SSH

### Option B: Droplets + Docker (fallback)

```
┌─────────────────────────────────────────────────┐
│  lobboss droplet (Docker + WireGuard)            │
│  ┌──────────────────────────────────────────┐   │
│  │ lobboss container (--network=host)        │   │
│  │ discord.py + Agent SDK + MCP tools        │   │
│  └──────────────────────────────────────────┘   │
│  Host: WireGuard, crons, vault on filesystem     │
└──────────────────┬──────────────────────────────┘
                   │ WireGuard + SSH
┌──────────────────▼──────────────────────────────┐
│  lobster droplet (Docker)                        │
│  ┌──────────────────────────────────────────┐   │
│  │ lobster container (workflow-specific)      │   │
│  │ Agent SDK + skills + run_task.py           │   │
│  └──────────────────────────────────────────┘   │
│  Trigger: SSH → docker exec run_task.py          │
└─────────────────────────────────────────────────┘
```

Same container images as DOKS. Can migrate from B→A without rebuilding.

### What Changes

| Component | Before (OpenClaw + Droplets) | After (Agent SDK + DOKS) |
|---|---|---|
| **lobboss runtime** | OpenClaw gateway + agent process | Agent SDK `ClaudeSDKClient` in k8s Deployment |
| **lobster runtime** | OpenClaw gateway on a droplet | Agent SDK `query()` in ephemeral k8s Job |
| **Lobster spawning** | `doctl compute droplet create` + cloud-init + SSH provision | `kubectl create job` (or k8s API from Python) |
| **Networking** | WireGuard mesh (hub-and-spoke) | k8s pod networking (native, no VPN) |
| **Discord handling** | OpenClaw's built-in (buggy) | discord.py bot (full control) |
| **Skill loading** | Lazy, unreliable | Explicit via `setting_sources` |
| **Message dedup** | None (8+ responses per message) | discord.py layer (message ID tracking) |
| **Thread context** | None (each message independent) | Session persistence per thread |
| **Tool execution** | OpenClaw tool system | SDK built-in + MCP custom tools |
| **System prompt** | Vault AGENTS.md (fragile) | Explicit `system_prompt` parameter |
| **Configuration** | openclaw.json (complex, brittle) | Python code (explicit, testable) |
| **Non-Claude models** | Not possible | MCP tools wrapping external APIs |
| **Secrets management** | SCP + env files | k8s Secrets |
| **Cron jobs** | System crontab on droplet | k8s CronJobs |
| **Pool management** | Custom bash script (pool-manager) | k8s node autoscaler (scale-to-zero) |
| **Workflow toolchains** | Same droplet image for all lobsters | Specialized container images per workflow |

### What Stays the Same

- **Vault structure** — 010-tasks/, 020-logs/, 030-knowledge/, 040-fleet/ unchanged
- **Task file format** — YAML frontmatter + markdown body unchanged
- **Skill files** — SKILL.md format unchanged, just loaded differently
- **Git workflow** — same branch strategy, same PR process
- **lobmob CLI** — updated commands, same interface (e.g. `lobmob spawn` creates a Job instead of a Droplet)

### Discord Bot Layer

The thin discord.py wrapper handles everything OpenClaw got wrong:

1. **Message dedup**: Track processed message IDs, skip duplicates
2. **Thread management**: Create threads for task proposals, post all responses in-thread
3. **Sequential processing**: asyncio queue, process one message at a time
4. **Channel routing**: Only respond in #task-queue, #swarm-control (ignore others)
5. **Session binding**: One Agent SDK session per Discord thread (persistent context)
6. **Reaction handling**: Monitor for "go" confirmation reactions/messages

### Custom MCP Tools

Core tools beyond built-ins (lobboss only):

1. **`spawn_lobster`** — Create a k8s Job for a lobster task
   - Input: task ID, lobster type (swe/qa/research), workflow image (unity/web/default)
   - Output: job name, pod status
   - On DOKS: creates a k8s Job with the appropriate container image
   - On Droplets (fallback): creates a Droplet + triggers via SSH

2. **`discord_post`** — Post messages to Discord channels/threads
   - Input: channel/thread ID, message content, optional message edit ID
   - Output: message ID for threading

3. **`lobster_status`** — Check status of running lobster Jobs/pods
   - Input: optional task ID or job name filter
   - Output: running/succeeded/failed, logs tail

### External Model Tools (MCP, as needed)

Non-Claude capabilities integrated as MCP tools. Claude reasons about *what* to do, then delegates specialized work via tool calls. Examples:

- **`image_generate`** — Wraps Gemini/DALL-E/etc. for image generation
- **`embed_text`** — Wraps an embedding model for semantic search
- **`ocr_extract`** — Wraps a vision model for document extraction

These are added incrementally as needed, not upfront. The MCP tool pattern means any API-accessible model capability can be exposed to the agent without changing the framework. Each tool is a thin Python function wrapping an API call — the agent never needs to "be" the other model, just call it.

### Skills vs MCP Tools

These are complementary, not competing:

**Skills** = instructions the agent reads and follows. Markdown documents loaded into context. The agent interprets them and executes multi-step workflows using its built-in tools and MCP tools.

- Flexible — agent can reason, adapt to edge cases, handle unexpected situations
- Consume context window (loaded into the prompt)
- Easy to write (markdown), easy to iterate on
- Less deterministic (agent might misinterpret or skip steps)

**MCP tools** = capabilities the agent invokes. Python functions with typed inputs and structured outputs. The agent calls them, code runs, result comes back.

- Deterministic — code runs exactly the same every time
- Don't consume context window (just the tool schema definition)
- Require code to implement
- More reliable for atomic operations

**Rule of thumb**: skills for workflows that need reasoning, MCP tools for atomic operations that need reliability. Skills can (and should) call MCP tools as part of their steps.

| Component | Type | Why |
|---|---|---|
| `task-create` | Skill | Multi-step with judgment (is this a real task? what priority? what type?) |
| `code-task` | Skill | Complex workflow, agent reasons about code, tests, edge cases |
| `review-prs` | Skill | Requires judgment (security, code quality, acceptance criteria) |
| `verify-task` | Skill | QA assessment, subjective evaluation |
| `ssh_exec` | MCP tool | Atomic, deterministic, no judgment needed |
| `discord_post` | MCP tool | Atomic, just send a message |
| `image_generate` | MCP tool | Thin wrapper around external API |
| `vault_commit` | MCP tool | Atomic git add/commit/push cycle |
| `spawn-lobster` | Skill → MCP tool | Start as skill for flexibility; convert to MCP tool once the procedure stabilizes and reliability matters more |

Skills that call MCP tools get the best of both worlds — flexible reasoning at the workflow level, reliable execution at the operation level. Example: the `task-create` skill says "post the proposal to Discord" and the agent calls the `discord_post` MCP tool to do it deterministically.

### Hooks

Replace the "CRITICAL RULES" in AGENTS.md that OpenClaw ignored:

- **PreToolUse (Bash)**: Block `rm -rf /`, `git push --force`, etc.
- **PostToolUse (ssh_exec)**: Log all SSH commands to 020-logs/
- **Stop**: Verify response will be posted to correct thread
- **SessionStart**: Load relevant skill based on channel/context

## Container-Based Dev/Deploy

### The Problem with the Current Loop

Edit scripts locally → SCP to droplet → test on droplet → observe behavior → repeat. Each iteration takes minutes, and agent behavior is the hardest thing to debug remotely.

### Container Strategy

Same container images run locally, on DOKS, and on raw droplets.

```
┌─────────────────────────────────────────────────────────┐
│  Local dev (docker-compose)                             │
│                                                         │
│  lobboss container          lobster container (optional) │
│  ├── discord.py bot         ├── run_task.py             │
│  ├── Agent SDK              ├── Agent SDK               │
│  ├── skills/ (bind mount)   ├── skills/ (bind mount)    │
│  ├── vault/ (bind mount)    └── vault/ (bind mount)     │
│  └── MCP tools                                          │
│                                                         │
│  No WireGuard needed — containers talk directly         │
│  Discord bot connects to real Discord (dev channels)    │
│  Vault is a local clone of lobmob-vault-dev             │
└─────────────────────────────────────────────────────────┘

Production: same images deployed to DOKS cluster or Droplets.
```

### What This Enables

- **Fast iteration**: edit skill markdown or Python code, `docker-compose restart`, test in seconds
- **Local testing**: full task lifecycle without deploying to the cloud
- **Parity**: same image, same dependencies, same behavior locally and in prod
- **Version pinning**: image tag = known-good configuration, easy rollback

### Image Structure

Layered images — base image with common dependencies, specialized images add workflow toolchains:

```
lobmob-base                    (Python + Node.js + Agent SDK)
├── lobmob-lobboss             (+ discord.py + MCP tools + lobboss skills)
├── lobmob-lobster             (+ lobster skills + run_task.py)
│   ├── lobmob-lobster-unity   (+ Unity Editor + Android SDK)
│   ├── lobmob-lobster-web     (+ browsers + Playwright)
│   └── lobmob-lobster-ml      (+ PyTorch + CUDA libs)
└── (future specialized images as needed)
```

See [Workflow-Specific Container Images](#workflow-specific-container-images) below for details.

**Registry**: GitHub Container Registry (GHCR) — free for public repos, integrates with existing GitHub App auth. DO Container Registry ($5/mo basic) is an alternative if we want images in the same datacenter for faster pulls.

### docker-compose.yml (local dev)

```yaml
services:
  lobboss:
    build: ./containers/lobboss
    env_file: secrets-dev.env
    volumes:
      - ./skills/lobboss:/app/skills:ro      # live-reload skills
      - ./vault-dev:/opt/vault               # local vault clone
    environment:
      - LOBMOB_ENV=dev
      - DISCORD_TOKEN=${DISCORD_TOKEN}
      - ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}

  lobster:  # generic lobster for testing
    build: ./containers/lobster
    env_file: secrets-dev.env
    volumes:
      - ./skills/lobster:/app/skills:ro
      - ./vault-dev:/opt/vault
    profiles: ["testing"]

  lobster-unity:  # Unity workflow for testing
    build: ./containers/lobster-unity
    env_file: secrets-dev.env
    volumes:
      - ./skills/lobster:/app/skills:ro
      - ./vault-dev:/opt/vault
    profiles: ["testing"]
```

### Migration Impact

This changes the deployment model significantly:

| Aspect | Before | After (DOKS) | After (Droplets fallback) |
|---|---|---|---|
| Deploy lobboss | TF + cloud-init + SCP | `kubectl apply` Deployment | cloud-init pulls Docker image |
| Deploy lobster | cloud-init + provision | `kubectl create job` | cloud-init pulls image + SSH trigger |
| Iterate on behavior | SCP → restart → logs | Edit → docker-compose restart | same as DOKS (local dev is identical) |
| Iterate on skills | SCP → clear sessions | Edit bind-mounted files | same |
| Rollback | Re-deploy previous scripts | `kubectl set image` to previous tag | `docker pull previous-tag` |
| Dependencies | cloud-init (fragile) | Baked into image | Baked into image |
| Networking | WireGuard mesh | k8s pod networking | WireGuard mesh |

## DOKS Infrastructure

### Why DOKS over raw Droplets

Other DO products were evaluated and don't fit:

- **App Platform**: 30-minute job timeout (lobsters need 30-90 min), no persistent storage, no inter-container networking, 15-minute minimum cron interval. Blocked on multiple requirements.
- **Functions**: 15-minute max timeout, 1 GB max memory. Wrong product category.
- **Gradient (GenAI Platform)**: Managed model hosting, not compute containers. Doesn't replace infrastructure.
- **GPU Droplets**: Massive overkill. Agents are I/O-bound (API calls, git), not GPU-bound.
- **No Fargate equivalent on DO** — DOKS with scale-to-zero worker pools is the closest thing.

### DOKS Cost Estimate

| Component | Cost |
|---|---|
| Control plane (standard) | **$0** (free) |
| Always-on node (lobboss + crons): s-2vcpu-4gb | $24/mo |
| Worker node pool (lobsters): scale-to-zero | $0 when idle, ~$0.025/hr per node when active |
| Block storage PVC (vault, 10 GB) | ~$1/mo |
| Container Registry (GHCR) | free |
| **Estimated total** | **~$25/mo base + variable lobster compute** |

With 2-3 lobsters running ~50% of the time: roughly **$45-55/mo** (comparable to current $36-66/mo).

### What DOKS Eliminates

- **WireGuard mesh** — pods communicate natively. No key management, no IP allocation, no tunnel debugging.
- **Cloud-init provisioning** — everything is in the container image. No more "cloud-init returned prematurely" bugs.
- **SSH key management** — no more `ssh-keygen -R`, no more `lobster_admin` keypair, no more known_hosts issues.
- **Pool manager script** — k8s node autoscaler handles node lifecycle. Scale-to-zero when idle.
- **Provision secrets script** — k8s Secrets injected as env vars or volume mounts.
- **Droplet lifecycle via doctl** — replaced by k8s Job API.

### What DOKS Requires (new)

- **Kubernetes manifests**: Deployment (lobboss), Job templates (lobsters), CronJobs (task-mgr, watchdog), PVCs, Secrets, RBAC.
- **Terraform DOKS resources**: `digitalocean_kubernetes_cluster`, node pools, container registry (if using DO).
- **k8s API integration**: lobboss creates Jobs programmatically via Python `kubernetes` client library.
- **Learning curve**: k8s concepts (pods, jobs, PVCs, namespaces, RBAC). Offset by eliminating WireGuard, cloud-init, and SSH provisioning complexity.

### DOKS Migration Path

Start on Droplets + Docker (simpler, validates containers work). Move to DOKS once containers are proven. The images are identical — only the deployment target changes.

## Workflow-Specific Container Images

### The Problem

Different tasks need different toolchains. A Unity C# task needs the Unity Editor + Android SDK. A web frontend task needs Node.js + browsers. A Python ML task needs PyTorch. Currently, all lobsters use the same droplet image — which means either installing everything on every droplet (bloated, slow) or not supporting specialized workflows.

### The Solution: Layered Images

```dockerfile
# containers/base/Dockerfile
FROM python:3.12-slim
RUN apt-get update && apt-get install -y git nodejs npm
RUN pip install claude-agent-sdk anthropic
RUN npm install -g @anthropic-ai/claude-code
COPY run_task.py /app/
COPY skills/ /app/skills/

# containers/lobster/Dockerfile
FROM lobmob-base
# Generic lobster — good for research, simple code tasks
ENTRYPOINT ["python", "/app/run_task.py"]

# containers/lobster-unity/Dockerfile
FROM lobmob-base
# Unity Editor (headless, Linux)
RUN apt-get install -y libgtk-3-0 libgbm1 libasound2 libvulkan1
RUN /opt/unity/UnitySetup -u 6000.0.39f1 -c Unity -c Android -c iOS --headless
ENV UNITY_PATH=/opt/unity/6000.0.39f1/Editor/Unity
# Android SDK
RUN sdkmanager "platforms;android-34" "build-tools;34.0.0" "ndk;26.1.10909125"
ENV ANDROID_HOME=/opt/android-sdk
ENTRYPOINT ["python", "/app/run_task.py"]

# containers/lobster-web/Dockerfile
FROM lobmob-base
RUN npx playwright install --with-deps chromium
RUN npm install -g typescript prettier eslint
ENTRYPOINT ["python", "/app/run_task.py"]
```

### How Lobboss Selects the Right Image

Task metadata gains a `workflow` field that maps to a container image:

```yaml
# 010-tasks/active/task-2026-02-12-a1b2.md
---
id: task-2026-02-12-a1b2
type: swe
workflow: unity          # ← maps to lobmob-lobster-unity image
model: opus
status: queued
---
```

Workflow-to-image mapping (configured in lobboss, not hardcoded in skills):

| `workflow` value | Container image | Includes |
|---|---|---|
| `default` | `lobmob-lobster` | Base tools only |
| `unity` | `lobmob-lobster-unity` | Unity Editor, Android/iOS SDKs, .NET SDK |
| `web` | `lobmob-lobster-web` | Playwright, Node.js toolchain, browsers |
| `ml` | `lobmob-lobster-ml` | PyTorch, CUDA, Jupyter |
| (custom) | Any image in registry | Whatever you put in the Dockerfile |

When lobboss creates a Job (DOKS) or spawns a container (Droplets), it selects the image based on the task's `workflow` field. The `task-create` skill can infer the workflow from context ("this is a Unity project, use the unity workflow") or the user can specify it explicitly.

### Image Size Considerations

Specialized images can be large:

| Image | Estimated size | Notes |
|---|---|---|
| `lobmob-base` | ~1 GB | Python + Node.js + Agent SDK |
| `lobmob-lobster` | ~1.2 GB | + git, common dev tools |
| `lobmob-lobster-unity` | ~15-20 GB | Unity Editor is huge |
| `lobmob-lobster-web` | ~2-3 GB | Chromium is ~500 MB |
| `lobmob-lobster-ml` | ~8-12 GB | PyTorch + CUDA libs |

Mitigations:
- **Layer caching**: Base layers shared across all images. Only workflow-specific layers differ.
- **Registry in same datacenter**: DO Container Registry or GHCR — pulls are fast within the DC.
- **Pre-pull on nodes**: For DOKS, configure a DaemonSet that pre-pulls large images onto worker nodes.
- **Multi-stage builds**: Keep final images lean by separating build-time and runtime dependencies.
- **Image pull once per node**: After first pull, subsequent Jobs on the same node start instantly.

### Advantages Over the Droplet Approach

| Aspect | Droplets | Containers |
|---|---|---|
| Adding a new workflow | Edit cloud-init, re-provision, test on live droplet | Write Dockerfile, build, test locally, push |
| Unity version update | Re-provision all Unity lobsters | Update Dockerfile, rebuild, push new tag |
| Multiple Unity versions | Multiple cloud-init templates or runtime install | Multiple image tags (`lobster-unity:6000.0.39f1`) |
| Workflow isolation | Everything installed on same droplet | Each workflow in its own image, no conflicts |
| Local testing | Need a droplet or replicate full setup | `docker-compose run lobster-unity` |
| Reproducibility | Drift over time (apt updates, etc.) | Immutable image, exact same every time |

### Custom Workflow Images

Adding a new workflow is self-service:

1. Create `containers/lobster-<workflow>/Dockerfile` extending `lobmob-base`
2. Install workflow-specific tools
3. Build and push: `docker build -t ghcr.io/minsley/lobmob-lobster-<workflow> . && docker push ...`
4. Add the workflow mapping to lobboss config
5. Use `workflow: <name>` in task files

No infrastructure changes needed. No Terraform. No cloud-init. Just a Dockerfile.

## Migration Scope

### Phase 1: lobboss (containerized, local + Droplets)

Build the lobboss agent as a Docker container, test locally, deploy to dev droplet.

- Base Dockerfile: Python + Node.js + Agent SDK
- Lobboss Dockerfile: + discord.py + MCP tools + lobboss skills
- Build discord.py bot layer
- Integrate Agent SDK as long-running `ClaudeSDKClient`
- Create custom MCP tools (spawn_lobster, discord_post, lobster_status)
- docker-compose for local dev (bind-mount skills + vault)
- Test full task lifecycle locally against dev Discord channels
- Deploy container to dev droplet (Docker on host), verify end-to-end

### Phase 2: lobsters (containerized, local + Droplets)

Build lobster containers, test locally, deploy to dev droplets.

- Lobster base Dockerfile: Python + Node.js + Agent SDK + `run_task.py`
- Build `run_task.py` script (Agent SDK `query()` → task execution → exit)
- Port lobster skills (code-task, verify-task, submit-results)
- Build at least one workflow image (e.g., lobster-unity) as proof of concept
- Test locally: run container with a task, verify it produces correct PR
- Deploy to dev droplet, test trigger from lobboss

### Phase 3: DOKS migration

Move from Droplets + Docker to DOKS. Same container images, different orchestration.

- Terraform: DOKS cluster, node pools (always-on + autoscaling)
- k8s manifests: lobboss Deployment, lobster Job templates, CronJobs, PVCs, Secrets
- Update lobboss MCP tools: `spawn_lobster` creates k8s Jobs instead of Droplets
- Remove WireGuard configuration
- Test full lifecycle on DOKS in dev
- Migrate prod

### Phase 4: external model tools (incremental)

Add non-Claude capabilities as MCP tools, driven by actual needs rather than upfront design.

- Each new capability = one MCP tool function wrapping an API
- No framework changes needed — just add tools to the MCP server config
- Rebuild and push container image to deploy new tools

### Why migrate lobsters too (not "if needed")

The post-mortem focused on Discord as the worst pain, but lobsters still hit OpenClaw's skill-loading reliability problem. When a lobster is SSH-triggered to execute a task, it still needs to reliably follow `code-task` or `verify-task` skills — and OpenClaw's lazy loading means it sometimes doesn't (the SWE lobster that "finished early" without creating a PR is likely a symptom of this).

Additional benefits:
- **One framework** to deploy, maintain, debug, and upgrade
- **Simpler provision** — no OpenClaw gateway process, no openclaw.json, no stale session cleanup
- **Better tools** — Agent SDK's built-in Read/Write/Edit/Bash/Glob/Grep are battle-tested
- **Ephemeral sessions** are a natural fit — lobster gets task, Agent SDK runs `query()`, process exits cleanly
- **Already meet requirements** — lobsters have Node.js (for OpenClaw) and ≥2GB RAM (for Opus), both needed by Agent SDK

## Decisions (from discussion)

These were resolved during research review and should be treated as settled:

1. **Framework**: Claude Agent SDK + discord.py. No other framework evaluated is competitive.
2. **Scope**: Both lobboss AND lobsters migrate. Not "lobboss now, lobsters later if needed." One framework, one stack.
3. **Multi-model strategy**: Claude is the agent brain. Non-Claude capabilities (image generation, embeddings, etc.) integrate as MCP tools — thin Python wrappers around external APIs. No need for a model-agnostic framework.
4. **Skills vs MCP tools**: Skills for multi-step workflows needing judgment (task-create, code-task, review-prs). MCP tools for atomic operations needing reliability (ssh_exec, discord_post, spawn_lobster). Skills call MCP tools. Some skills graduate to MCP tools as procedures stabilize.
5. **Containers**: All agents containerized. Layered images: base → lobboss / lobster → workflow-specific (unity, web, ml). Same images run locally (docker-compose) and in production.
6. **Workflow-specific images**: Task metadata gains a `workflow` field. Lobboss selects the appropriate container image when spawning a lobster. Adding a new workflow = write a Dockerfile, build, push, add mapping. No infra changes.
7. **Infrastructure**: DOKS (managed Kubernetes) as target deployment. Free control plane. k8s Jobs for ephemeral lobsters, native pod networking eliminates WireGuard, node autoscaling replaces pool-manager. Start on Droplets+Docker for initial validation if needed.
8. **Migration path**: Containerize first (works on Droplets), then migrate to DOKS. Container images are identical for both targets.

## Implementation Decisions (resolved)

9. **Language**: Python. discord.py for Discord, Python Agent SDK for agents. Node.js still required on host (Agent SDK runtime dependency) but all custom code is Python.
10. **Deployment path**: Straight to DOKS. Skip intermediate Droplets+Docker phase. Avoids building WireGuard/SSH plumbing that gets thrown away.
11. **Cron scripts**: Keep as bash for now. Package into lobboss container or run as k8s CronJobs. Evaluate Python rewrite later after migration stabilizes.
12. **Workflow images**: Deferred. Get base lobster image working first. Unity/web/ML images are additive, built when needed.

## Open Questions (remaining)

1. **Python or TypeScript?** — Both SDKs available. Python + discord.py is the most natural fit. TypeScript + discord.js is an option if we want to stay in the Node.js ecosystem.

2. **Session persistence** — In-memory (simple, lost on restart) vs SQLite PVC (survives pod restarts). Only relevant for lobboss (lobster sessions are ephemeral).

3. **Cold start mitigation** — Keep the Agent SDK process warm between messages (streaming input mode), or accept the ~12s latency per new thread? Streaming input mode for lobboss; lobsters take the cold start since they're one-shot.

4. **Skill injection method** — Use `setting_sources` to load from filesystem, or inject skill content directly into `system_prompt`? Filesystem is cleaner and matches the bind-mount dev workflow.

5. **Cron scripts** — On DOKS, these become k8s CronJobs. Task-manager currently posts to Discord via OpenClaw gateway API — needs a new mechanism (HTTP endpoint on the discord.py bot, or direct Discord API calls from the CronJob).

6. **DOKS node sizing** — Always-on node needs to fit lobboss + CronJobs. s-2vcpu-4gb ($24/mo) should be sufficient. Lobster worker nodes need ≥2GB for Opus; s-2vcpu-4gb allows running 1-2 lobster pods per node.

7. **Container registry** — GHCR (free, GitHub App auth) vs DO Container Registry ($5/mo basic, same-datacenter pulls). GHCR default unless pull latency for large Unity images is a problem.

8. **Workflow image build pipeline** — Manual `docker build && push`, or CI/CD (GitHub Actions on Dockerfile changes)? For large images like Unity, build time matters.

9. **DOKS vs Droplets timing** — Start on Droplets+Docker (Phase 1-2) to validate containers, then migrate to DOKS (Phase 3)? Or go straight to DOKS? Starting with Droplets reduces initial scope but means building WireGuard/SSH plumbing that gets thrown away.

10. **Unity Editor licensing** — Unity headless builds on Linux require a license. Need to handle activation in the container (CI license, floating license, or serial number via k8s Secret).

## References

### Claude Agent SDK
- [Overview](https://platform.claude.com/docs/en/agent-sdk/overview)
- [Quickstart](https://platform.claude.com/docs/en/agent-sdk/quickstart)
- [Python GitHub](https://github.com/anthropics/claude-agent-sdk-python)
- [TypeScript GitHub](https://github.com/anthropics/claude-agent-sdk-typescript)
- [Subagents](https://platform.claude.com/docs/en/agent-sdk/subagents)
- [Custom Tools / MCP](https://platform.claude.com/docs/en/agent-sdk/custom-tools)
- [Hosting Guide](https://platform.claude.com/docs/en/agent-sdk/hosting)
- [Demo Agents](https://github.com/anthropics/claude-agent-sdk-demos)
- [Advanced Tool Use](https://www.anthropic.com/engineering/advanced-tool-use)

### DigitalOcean
- [DOKS Pricing](https://docs.digitalocean.com/products/kubernetes/details/pricing/) — free control plane
- [DOKS Autoscaling / Scale-to-Zero](https://docs.digitalocean.com/products/kubernetes/how-to/autoscale/)
- [DOKS VPC-Native Networking](https://www.digitalocean.com/blog/vpc-native-clusters)
- [DOKS Persistent Volumes](https://docs.digitalocean.com/products/kubernetes/how-to/add-volumes/)
- [App Platform Limits](https://docs.digitalocean.com/products/app-platform/details/limits/) — 30-min job timeout
- [Functions Limits](https://docs.digitalocean.com/products/functions/details/limits/) — 15-min timeout
- [Droplet Pricing](https://docs.digitalocean.com/products/droplets/details/pricing/)

### Other Frameworks (evaluated, not selected)
- [Pydantic AI](https://ai.pydantic.dev/)
- [CrewAI](https://docs.crewai.com/en/introduction)
- [LangGraph](https://www.langchain.com/langgraph)
- [OpenAI Agents SDK](https://openai.github.io/openai-agents-python/)
- [Microsoft Agent Framework](https://learn.microsoft.com/en-us/agent-framework/overview/agent-framework-overview)
