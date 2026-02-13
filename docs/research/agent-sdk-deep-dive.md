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

Unified approach — both lobboss and lobsters on the Claude Agent SDK.

```
┌─────────────────────────────────────────────────┐
│                  lobboss droplet                 │
│                                                  │
│  ┌──────────────┐     ┌──────────────────────┐  │
│  │  discord.py   │────▶│  Claude Agent SDK     │  │
│  │  bot layer    │◀────│  (lobboss agent)      │  │
│  │               │     │                       │  │
│  │  - dedup      │     │  - Built-in tools     │  │
│  │  - threading  │     │  - MCP: ssh_exec      │  │
│  │  - routing    │     │  - MCP: discord_post  │  │
│  │  - sequential │     │  - MCP: external APIs  │  │
│  │    processing │     │  - Skills (SKILL.md)  │  │
│  │  - reactions  │     │  - Hooks (validation)  │  │
│  └──────────────┘     └──────────────────────┘  │
│                                                  │
│  ┌──────────────┐     ┌──────────────────────┐  │
│  │  Cron jobs    │     │  /opt/vault           │  │
│  │  (unchanged)  │     │  (unchanged)          │  │
│  │               │     │                       │  │
│  │  - task-mgr   │     │  - 010-tasks/         │  │
│  │  - pool-mgr   │     │  - 020-logs/          │  │
│  │  - watchdog   │     │  - 040-fleet/         │  │
│  │  - review-prs │     │  - AGENTS.md          │  │
│  └──────────────┘     └──────────────────────┘  │
│                                                  │
│  ┌──────────────────────────────────────────┐   │
│  │  WireGuard (10.0.0.1) ──▶ lobsters       │   │
│  └──────────────────────────────────────────┘   │
└─────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────┐
│              lobster droplet (each)              │
│                                                  │
│  ┌──────────────────────────────────────────┐   │
│  │  Claude Agent SDK (ephemeral session)     │   │
│  │                                           │   │
│  │  - Built-in tools (Read/Write/Edit/Bash)  │   │
│  │  - Skills: code-task, verify-task, etc.   │   │
│  │  - MCP: external APIs (if needed)         │   │
│  │  - Model: Opus (swe) or Sonnet (qa)       │   │
│  └──────────────────────────────────────────┘   │
│                                                  │
│  Trigger: SSH from lobboss                       │
│    → python run_task.py --task <task-id>         │
│    → Agent SDK query() with task + skills        │
│    → Agent works, commits, creates PR            │
│    → Process exits                               │
└─────────────────────────────────────────────────┘
```

### What Changes

| Component | Before (OpenClaw) | After (Agent SDK) |
|---|---|---|
| **lobboss runtime** | OpenClaw gateway + agent process | Agent SDK `ClaudeSDKClient` (long-running) |
| **lobster runtime** | OpenClaw gateway + agent process | Agent SDK `query()` (ephemeral per-task) |
| **Discord handling** | OpenClaw's built-in (buggy) | discord.py bot (full control) |
| **Skill loading** | Lazy, unreliable | Explicit via `setting_sources` |
| **Message dedup** | None (8+ responses per message) | discord.py layer (message ID tracking) |
| **Thread context** | None (each message independent) | Session persistence per thread |
| **Tool execution** | OpenClaw tool system | SDK built-in + MCP custom tools |
| **System prompt** | Vault AGENTS.md (fragile) | Explicit `system_prompt` parameter |
| **Configuration** | openclaw.json (complex, brittle) | Python code (explicit, testable) |
| **Non-Claude models** | Not possible | MCP tools wrapping external APIs |
| **Lobster trigger** | SSH → OpenClaw agent command | SSH → `python run_task.py --task <id>` |

### What Stays the Same

- **Vault structure** — 010-tasks/, 020-logs/, 030-knowledge/, 040-fleet/ unchanged
- **Task file format** — YAML frontmatter + markdown body unchanged
- **Skill files** — SKILL.md format unchanged, just loaded differently
- **Cron scripts** — task-manager, pool-manager, watchdog, review-prs unchanged
- **Deployment scripts** — lobmob CLI, SCP deploy, provision updated (swap openclaw install for agent-sdk + Node.js)
- **WireGuard mesh** — same topology, same IPs
- **Git workflow** — same branch strategy, same PR process

### Discord Bot Layer

The thin discord.py wrapper handles everything OpenClaw got wrong:

1. **Message dedup**: Track processed message IDs, skip duplicates
2. **Thread management**: Create threads for task proposals, post all responses in-thread
3. **Sequential processing**: asyncio queue, process one message at a time
4. **Channel routing**: Only respond in #task-queue, #swarm-control (ignore others)
5. **Session binding**: One Agent SDK session per Discord thread (persistent context)
6. **Reaction handling**: Monitor for "go" confirmation reactions/messages

### Custom MCP Tools

Core tools beyond built-ins:

1. **`ssh_exec`** — Run commands on lobsters over WireGuard SSH (lobboss only)
   - Input: host (WireGuard IP), command, optional timeout
   - Output: stdout + stderr + exit code

2. **`discord_post`** — Post messages to Discord channels/threads (lobboss only)
   - Input: channel/thread ID, message content, optional message edit ID
   - Output: message ID for threading

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

Same image runs locally and on droplets. One Dockerfile per agent type.

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

┌─────────────────────────────────────────────────────────┐
│  Production droplet                                     │
│                                                         │
│  Host: WireGuard + Docker                               │
│  └── same container image                               │
│      ├── --network=host (for WG access)                 │
│      └── vault/ (mount from host /opt/vault)            │
│                                                         │
│  Cloud-init: install Docker, pull image, run container  │
│  Provision: push secrets into container env / volume    │
└─────────────────────────────────────────────────────────┘
```

### What This Enables

- **Fast iteration**: edit skill markdown or Python code, `docker-compose restart`, test in seconds
- **Local testing**: full task lifecycle without deploying a droplet
- **Parity**: same image, same dependencies, same behavior locally and in prod
- **Simpler cloud-init**: install Docker + pull image, instead of installing Node.js + Python + OpenClaw + configuring everything
- **Version pinning**: image tag = known-good configuration, easy rollback

### WireGuard Considerations

- **Local dev**: skip WG entirely. Containers talk directly. If testing SSH to a real lobster, use the host's WG interface.
- **Production**: WG runs on the host. Container uses `--network=host` to access the WG interface, or a sidecar WG container shares the network namespace.
- **Lobster droplets**: same pattern — WG on host, agent container uses host networking.

### Image Structure

Two images (or one with entrypoint selection):

1. **`lobmob-lobboss`**: Python + Node.js + Agent SDK + discord.py + MCP tools + lobboss skills
2. **`lobmob-lobster`**: Python + Node.js + Agent SDK + lobster skills + `run_task.py` entrypoint

Registry: GitHub Container Registry (GHCR) is free for public repos and integrates with our existing GitHub App auth. DO Container Registry is an alternative if we want to keep things in the DO ecosystem.

### docker-compose.yml (local dev)

```yaml
services:
  lobboss:
    build: ./containers/lobboss
    env_file: secrets-dev.env
    volumes:
      - ./skills/lobboss:/app/skills:ro      # live-reload skills
      - ./vault-dev:/opt/vault               # local vault clone
      - ./openclaw/lobboss:/app/persona:ro   # agent persona
    environment:
      - LOBMOB_ENV=dev
      - DISCORD_TOKEN=${DISCORD_TOKEN}
      - ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}

  lobster:  # optional, for local task testing
    build: ./containers/lobster
    env_file: secrets-dev.env
    volumes:
      - ./skills/lobster:/app/skills:ro
      - ./vault-dev:/opt/vault
    profiles: ["testing"]  # only start when explicitly requested
```

### Migration Impact

This changes the deployment model significantly:

| Aspect | Before | After |
|---|---|---|
| Deploy lobboss | Terraform + cloud-init + SCP scripts | Terraform + cloud-init pulls Docker image |
| Deploy lobster | cloud-init + provision-secrets | cloud-init pulls Docker image + inject secrets |
| Iterate on agent behavior | SCP → restart systemd → check logs | Edit locally → docker-compose restart → check logs |
| Iterate on skills | SCP → clear sessions → restart | Edit bind-mounted files → restart (or live-reload) |
| Rollback | Re-deploy previous scripts | `docker pull previous-tag && docker restart` |
| Dependencies | Installed via cloud-init (fragile) | Baked into image (reproducible) |

## Migration Scope

### Phase 1: lobboss (containerized)

Build the lobboss agent as a Docker container, test locally, then deploy to droplet.

- Dockerfile: Python + Node.js + Agent SDK + discord.py + MCP tools
- Build discord.py bot layer
- Integrate Agent SDK as long-running `ClaudeSDKClient`
- Create custom MCP tools (ssh_exec, discord_post)
- Port lobboss skills to Agent SDK format
- docker-compose for local dev (bind-mount skills + vault)
- Test full task lifecycle locally against dev Discord channels
- Deploy container to dev droplet, verify with WireGuard
- Update cloud-init to pull and run container instead of installing OpenClaw

### Phase 2: lobsters (containerized)

Same pattern — build container, test locally, deploy to droplets.

- Dockerfile: Python + Node.js + Agent SDK + lobster skills + `run_task.py` entrypoint
- Build `run_task.py` script (SSH trigger → Agent SDK `query()` → task execution → exit)
- Port lobster skills (code-task, verify-task, submit-results)
- Test locally: run container with a task, verify it produces correct PR
- Deploy to dev droplet, test SSH trigger from lobboss
- Update lobster cloud-init to pull and run container

### Phase 3: external model tools (incremental)

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

## Open Questions for Planning

1. **Python or TypeScript for the wrapper?** — Both SDKs available. Python + discord.py is the most natural fit for lobboss. Lobsters could use either. TypeScript + discord.js is an option if we want to stay in the Node.js ecosystem.

2. **Session persistence strategy** — In-memory (simple, lost on restart) vs SQLite (survives restarts). For a single-droplet deployment, SQLite may be sufficient. Only relevant for lobboss (lobster sessions are ephemeral).

3. **Cold start mitigation** — Keep the Agent SDK process warm between messages (streaming input mode), or accept the ~12s latency per new thread? Streaming input mode seems like the obvious choice for lobboss. Lobsters take the cold start since they're one-shot.

4. **Skill injection method** — Use `setting_sources` to load from filesystem, or inject skill content directly into `system_prompt`? Filesystem is cleaner but requires the files to be in the right place on each machine.

5. **Cron script interaction** — Task-manager currently posts to Discord via OpenClaw gateway API. After migration, it needs a new endpoint (the discord.py bot process, or a simple HTTP API alongside it).

6. **Rollback plan** — Keep OpenClaw config intact during dev testing so we can revert quickly. Remove OpenClaw only after prod migration is validated.

7. **Lobster trigger mechanism** — Currently SSH → `openclaw agent run`. Becomes SSH → `docker exec` or `python run_task.py --task <id>` inside the container. Lobboss SSHs to host, which runs the task inside the lobster container.

8. **Container registry** — GHCR (free, GitHub App auth integration) vs DO Container Registry (in-ecosystem, paid). GHCR is the default choice unless there's a reason to use DO.

9. **Live-reload vs rebuild** — For skills (markdown), bind-mount and live-reload. For Python code changes (MCP tools, discord bot), rebuild image. Consider a dev mode that watches for changes.

10. **Cron scripts in containers** — Task-manager, pool-manager, watchdog currently run as host cron jobs. Options: (a) keep them on host, talk to container via HTTP/socket, (b) move them into the container, (c) hybrid — deterministic scripts on host, agent-dependent ones in container.

## References

- [Claude Agent SDK Overview](https://platform.claude.com/docs/en/agent-sdk/overview)
- [Agent SDK Quickstart](https://platform.claude.com/docs/en/agent-sdk/quickstart)
- [Agent SDK Python GitHub](https://github.com/anthropics/claude-agent-sdk-python)
- [Agent SDK TypeScript GitHub](https://github.com/anthropics/claude-agent-sdk-typescript)
- [Agent SDK Subagents](https://platform.claude.com/docs/en/agent-sdk/subagents)
- [Agent SDK Custom Tools](https://platform.claude.com/docs/en/agent-sdk/custom-tools)
- [Agent SDK Hosting](https://platform.claude.com/docs/en/agent-sdk/hosting)
- [Agent SDK Demos](https://github.com/anthropics/claude-agent-sdk-demos)
- [Anthropic Advanced Tool Use](https://www.anthropic.com/engineering/advanced-tool-use)
- [Pydantic AI Docs](https://ai.pydantic.dev/)
- [CrewAI Docs](https://docs.crewai.com/en/introduction)
- [LangGraph](https://www.langchain.com/langgraph)
- [OpenAI Agents SDK](https://openai.github.io/openai-agents-python/)
- [Microsoft Agent Framework](https://learn.microsoft.com/en-us/agent-framework/overview/agent-framework-overview)
