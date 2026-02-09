# OpenClaw Post-Mortem: Why We're Migrating Away

## Date: 2026-02-09

## Summary

After extensive testing across multiple deployment cycles, OpenClaw cannot reliably serve as the agent framework for lobboss (the swarm coordinator). The issues are platform-level limitations, not configuration problems.

## Evidence

### Test 1: Dev Environment (2026-02-08)
- Lobboss bypassed task-lifecycle skill entirely, wrote code directly
- Root cause: vault AGENTS.md was generic (not coordinator). Fixed.

### Test 2: Prod with Updated AGENTS.md (2026-02-09, attempt 1)
- 3 duplicate proposals posted (non-threaded)
- Lobboss executed the work itself after proposals, creating rogue PR #2
- Root cause: stale skill files on lobboss. Fixed with rm+copy in provision.

### Test 3: Prod with All Fixes (2026-02-09, attempt 2)
- ENOENT on task-lifecycle SKILL.md (race condition with gateway start)
- 4 different proposals before reading the correct skill
- Thread created but agent didn't post confirmation prompt in it
- Root cause: gateway started before skills were deployed. Fixed with stop-before-config.

### Test 4: Prod with Gateway Ordering Fix (2026-02-09, attempt 3)
- **8+ responses to a single message** — no deduplication
- **3 separate task IDs created** from one request
- Skill loaded on attempt 5 out of 8, but the other 7 responses ignored it
- Most responses posted to channel, not thread (despite explicit instructions)
- A research lobster somehow responded in the thread instead of lobboss
- GitHub auth failed on lobboss despite provision setting it up
- **This is the definitive test.** The AGENTS.md had explicit "CRITICAL RULES" saying: read skill first, reply in thread, one response per message, never execute directly. All four rules were violated.

## Root Causes (Platform-Level)

1. **No message deduplication** — OpenClaw fires multiple responses to a single Discord message (known bug #3549)
2. **No skill preloading** — skills are lazy-loaded at the agent's discretion; no config to force it (known issue #9469)
3. **No thread context** — each message processed independently, agent doesn't maintain conversation state across thread messages
4. **AGENTS.md prose is metadata only** — routing instructions in vault workspace files are read but not reliably followed
5. **No sequential processing** — concurrent message handling leads to race conditions

## What We Tried

- Explicit AGENTS.md routing instructions with "CRITICAL RULES" section
- Stopping gateway before skill deployment (ordering fix)
- Clearing stale sessions after skill updates
- Compact proposal format to avoid message splitting
- Thread-on-user-message instead of thread-on-proposal
- Multiple redeploy cycles from clean state

## Decision

Migrate from OpenClaw to **Claude Agent SDK + discord.py** for the lobboss coordinator agent. This gives:
- Explicit skill loading control
- Custom Discord message handling (threading, deduplication)
- Sequential message processing
- Anthropic's official framework with production support

## Migration Plan

- Branch: `agent-sdk-migration` (off develop, not main)
- Scope: Replace OpenClaw on lobboss only (lobsters can stay on OpenClaw for now since their issues are less critical — they respond to SSH triggers, not Discord)
- Test in dev environment before any prod changes
- Preserve all existing skills (they're markdown, framework-agnostic)
- Keep the same vault, task files, and deployment scripts

## What OpenClaw Did Well

- Quick initial setup with Discord integration
- Gateway + agent model worked for simple single-response scenarios
- Skill system concept (SKILL.md files) is good — we'll keep the format
- Discord channel allowlist configuration was straightforward
