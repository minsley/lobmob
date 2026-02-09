# Agent Framework Comparison (Feb 2026)

## Context

OpenClaw has known issues with skill loading reliability, duplicate Discord messages, and lack of thread context. This research evaluates alternatives for running the lobboss/lobster agents.

## OpenClaw Issues (Confirmed)

- **Lazy loading by design** — no way to force skill preloading or guarantee execution
- **Duplicate Discord messages** — known bug ([#3549](https://github.com/openclaw/openclaw/issues/3549))
- **Skills show enabled but disabled** — known bug ([#9469](https://github.com/openclaw/openclaw/issues/9469))
- **AGENTS.md prose not in system prompt** — only metadata (name, model) is used; routing must go in vault workspace files
- **No sequential message processing** — each message processed independently, no thread context inheritance
- **No force-preload config** — skills load on-demand when agent decides to use them

## Top Alternatives

### 1. Claude Agent SDK (Recommended)
Anthropic's official framework, same tools as Claude Code.

- **Skill control**: Explicit via `settingSources` config (default: no skills loaded)
- **Tools**: Read, Write, Edit, Bash, Glob, Grep, WebSearch, WebFetch
- **Hooks**: PreToolUse, PostToolUse, Stop, SessionStart, SessionEnd
- **Discord**: Not native — needs discord.py/discord.js wrapper
- **Maintained by**: Anthropic
- **Docs**: [Overview](https://platform.claude.com/docs/en/agent-sdk/overview) | [Skills](https://platform.claude.com/docs/en/agent-sdk/skills) | [Python](https://github.com/anthropics/claude-agent-sdk-python) | [TypeScript](https://github.com/anthropics/claude-agent-sdk-typescript)

### 2. Direct Anthropic API + discord.py
Maximum control, most boilerplate.

- Full control over tool routing, threading, message handling
- Guarantee "read this skill before responding" in system prompt
- Implement tool loop yourself (handle tool_use stop_reason)
- Examples: [Claude Discord Bot](https://github.com/inside-out-gear/Claude-AI-Discord-Bot)

### 3. ElizaOS
Only framework with native Discord built-in.

- TypeScript, 90+ plugins, character-based agents
- Native Discord, Telegram, Twitter connectors
- Web3-heavy community (may be overkill for us)
- **Docs**: [elizaos.ai](https://docs.elizaos.ai) | [GitHub](https://github.com/elizaOS/eliza)

### 4. LangGraph
Best for state machine workflows.

- Explicit state management for multi-step flows
- Good fit for proposal → confirm → create → assign pipeline
- Python, steep learning curve
- **Docs**: [Tutorial](https://www.freecodecamp.org/news/build-a-langgraph-composio-powered-discord-bot/)

## Comparison Matrix

| Feature | OpenClaw | Claude Agent SDK | ElizaOS | LangGraph | Direct API |
|---|---|---|---|---|---|
| Native Discord | Yes | No | Yes | No | No |
| Force skill loading | No | Yes | Yes | N/A | You control |
| Reliable routing | Issues | Yes | Yes | Yes (state machine) | Yes |
| Sequential processing | No | Hooks | Not default | Yes | You implement |
| Duplicate messages | Known bug | N/A | Not reported | N/A | N/A |
| Language | TypeScript | Python/TS | TypeScript | Python | Any |
| Maintained by | Community | Anthropic | Community | LangChain | Anthropic |

## Recommendation

**Claude Agent SDK + discord.py wrapper** for lobboss. Gives us:
- Anthropic's own agent framework with explicit skill control
- Thin Discord bot layer for message handling and threading
- Can enforce "read skill → respond once → in thread" deterministically
- Same tool ecosystem as Claude Code
