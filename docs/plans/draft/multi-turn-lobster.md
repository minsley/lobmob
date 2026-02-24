---
status: draft
tags: [lobster, agent-sdk, ipc, attach]
maturity: ready
created: 2026-02-23
updated: 2026-02-23
---
# Multi-turn Lobster Execution + Attach/Inject

## Summary

Lobsters currently use one-shot `query()`: the agent runs to completion, then we verify and retry from scratch if steps are missing. Switching to episodic multi-turn via `ClaudeSDKClient` eliminates context loss on retry, moves verification between episodes (agent has full history when continuing), and enables mid-task injection from operators or lobboss via a new `lobmob attach` command.

## Open Questions

- [ ] Should `MAX_OUTER_TURNS` be configurable per task (e.g. via task metadata)?
- [ ] Should injections from `lobmob attach` be logged to the lobwife event log (via `_api_log_event`)?
- [ ] Should the SSE event panel in the dashboard persist across page refreshes (store in sessionStorage)?

## Architecture

```
run_task.py main_async()
  ├── create event_queue + inject_queue
  ├── start LobsterIPC server (:8090, localhost only)
  ├── await agent.run_task(config, body, event_queue, inject_queue)
  │     ├── ClaudeSDKClient.connect()  [persistent across episodes]
  │     ├── Episode 0: client.query(initial_prompt)
  │     │     └── receive_response() → emit events → ResultMessage
  │     ├── verify_completion() → [PASS → done] [FAIL → continue]
  │     ├── Episode 1: client.query(continue_prompt + injections)
  │     │     └── ...
  │     ├── ...up to MAX_OUTER_TURNS=5
  │     └── client.disconnect()
  └── stop IPC server, PATCH API status

LobsterIPC (aiohttp, :8090)
  ├── GET  /events  → SSE stream (fan-out from event_queue)
  ├── POST /inject  → enqueue to inject_queue + echo to event_queue
  └── GET  /health  → {"status": "ok", "sse_clients": N}

lobmob-web-lobster.js (Node.js, :8080)
  ├── [existing endpoints unchanged]
  ├── GET  /api/events  → proxy → :8090/events
  ├── POST /api/inject  → proxy → :8090/inject
  └── dashboard HTML: SSE event panel added

lobmob attach <job>
  ├── kubectl port-forward pod/:8080 → localhost:18080
  ├── curl -sN .../api/events | format + print
  └── readline loop → POST /api/inject
```

## Phases

### Phase 1: Multi-turn Episode Loop (`agent.py`)

- **Status**: pending

**Imports — add, remove:**
```python
# ADD
from claude_agent_sdk import ClaudeSDKClient
from common.vault import pull_vault
from lobster.verify import verify_completion

# REMOVE
# from claude_agent_sdk import query   ← no longer used
# _as_stream() helper ← delete (ClaudeSDKClient.query() takes string)
```

**New `run_task()` signature:**
```python
async def run_task(
    config: LobsterConfig,
    task_body: str,
    event_queue: asyncio.Queue | None = None,
    inject_queue: asyncio.Queue | None = None,
) -> dict:
```

**Episode loop:**
```python
MAX_OUTER_TURNS = 5

client = ClaudeSDKClient(options=options)
await client.connect()
try:
    prompt = f"## Task: {config.task_id}\n\n{task_body}"
    missing = []

    for outer_turn in range(MAX_OUTER_TURNS):
        if outer_turn > 0:
            injections = _drain_inject_queue(inject_queue)
            prompt = _build_continue_prompt(config.task_id, missing, injections)
            if injections:
                await _emit(event_queue, "inject", {"messages": injections})

        await _emit(event_queue, "turn_start", {"outer_turn": outer_turn})
        await client.query(prompt)

        async for message in client.receive_response():
            if isinstance(message, AssistantMessage):
                for block in message.content:
                    if isinstance(block, TextBlock):
                        result["responses"].append(block.text)
                        await _emit(event_queue, "text", {"text": block.text})
            elif isinstance(message, ResultMessage):
                result["cost_usd"] += message.total_cost_usd or 0
                result["num_turns"] += message.num_turns
                result["is_error"] = message.is_error
                result["session_id"] = message.session_id
                await _emit(event_queue, "turn_end", {
                    "outer_turn": outer_turn,
                    "inner_turns": message.num_turns,
                    "cost_usd": message.total_cost_usd,
                    "is_error": message.is_error,
                })
                if message.is_error:
                    break

        if result["is_error"]:
            break

        try:
            await pull_vault(config.vault_path)
        except Exception:
            pass

        missing = await verify_completion(
            config.task_id, config.lobster_type, config.vault_path
        )
        await _emit(event_queue, "verify", {"outer_turn": outer_turn, "missing": missing})

        if not missing:
            break
finally:
    try:
        await client.disconnect()
    except Exception:
        pass

await _emit(event_queue, "done", {"is_error": result["is_error"], "cost_usd": result["cost_usd"]})
```

Note: `result["cost_usd"]` starts as `0` (not `None`) to allow `+=` accumulation.

**New helpers:**

```python
async def _emit(q: asyncio.Queue | None, event_type: str, data: dict) -> None:
    if q is None:
        return
    import time
    try:
        q.put_nowait({"type": event_type, "ts": time.time(), **data})
    except asyncio.QueueFull:
        logger.warning("Event queue full — dropping %s", event_type)

def _drain_inject_queue(q: asyncio.Queue | None) -> list[str]:
    if not q:
        return []
    items = []
    while True:
        try:
            items.append(q.get_nowait())
        except asyncio.QueueEmpty:
            break
    return items

def _build_continue_prompt(task_id: str, missing: list[str], injections: list[str]) -> str:
    path = _resolve_prompt_path("continue.md")
    if path:
        tmpl = path.read_text()
        missing_str = "\n".join(f"- {s}" for s in missing)
        inject_str = "\n".join(f"- {m}" for m in injections) if injections else "(none)"
        return tmpl.replace("{task_id}", task_id) \
                   .replace("{missing_steps}", missing_str) \
                   .replace("{operator_messages}", inject_str)
    # Inline fallback
    lines = [f"## Continue: {task_id}", "", "The following steps remain incomplete:"]
    lines += [f"- {s}" for s in missing]
    if injections:
        lines += ["", "Operator messages:"] + [f"- {m}" for m in injections]
    lines += ["", "Review what's already done, then complete only the missing steps."]
    return "\n".join(lines)
```

**`_make_tool_checker` — wrap existing hook to emit events:**
```python
def _make_tool_checker(config: LobsterConfig, event_queue: asyncio.Queue | None):
    inner = create_tool_checker(config.lobster_type)
    async def check_tool(tool_name, tool_input, context):
        await _emit(event_queue, "tool_start", {"tool": tool_name, "input": tool_input})
        return await inner(tool_name, tool_input, context)
    return check_tool
```
Pass `can_use_tool=_make_tool_checker(config, event_queue)` in `ClaudeAgentOptions`.

**`run_retry()` — mark deprecated, leave body intact.** Remove in follow-up cleanup.

**New prompt file: `src/lobster/prompts/continue.md`** — placeholders: `{task_id}`, `{missing_steps}`, `{operator_messages}`.

---

### Phase 2: IPC Server (`src/lobster/ipc.py`, new file)

- **Status**: pending

```python
import asyncio, json, logging, time
from aiohttp import web

HOST = "127.0.0.1"
PORT = 8090

class LobsterIPC:
    def __init__(self, event_queue, inject_queue): ...
    async def start(self): ...   # AppRunner + TCPSite + broadcast task
    async def stop(self): ...    # cancel task, close SSE clients, cleanup runner

    async def _broadcast_loop(self):
        # await event_queue.get() → fan-out to all SSE clients

    async def _handle_sse(self, request):
        # StreamResponse, pipe connection, hold with request.wait_for_disconnect()

    async def _handle_inject(self, request):
        # parse JSON, inject_queue.put(), echo to event_queue, return 202

    async def _handle_health(self, request):
        # {"status": "ok", "sse_clients": N}
```

**Event types:**

| type | key fields |
|------|-----------|
| `turn_start` | `outer_turn` |
| `tool_start` | `tool`, `input` |
| `text` | `text`, `outer_turn` |
| `turn_end` | `outer_turn`, `inner_turns`, `cost_usd`, `is_error` |
| `verify` | `outer_turn`, `missing` |
| `inject` | `messages` (list) |
| `done` | `is_error`, `cost_usd` |
| `error` | `message` |

SSE format: `data: {json}\n\n`. Bound to `127.0.0.1` only.

---

### Phase 3: Sidecar Proxy (`lobmob-web-lobster.js`)

- **Status**: pending

Add `proxyToIpc(req, res, ipcPath, method)` helper:
- Proxies to `127.0.0.1:8090`
- Retries up to 5× with 500ms backoff (handles startup race)
- For SSE: pipe `proxyRes` directly into `res` to preserve streaming
- For POST: pipe `req` into `proxyReq`
- Returns 503 after retries exhausted

Add to request handler:
```javascript
if (url.pathname === '/api/events') {
  proxyToIpc(req, res, '/events', 'GET'); return;
}
if (url.pathname === '/api/inject' && req.method === 'POST') {
  proxyToIpc(req, res, '/inject', 'POST'); return;
}
```

Add SSE event panel to dashboard HTML (below log-box section):
- `<div id="events">` with auto-scroll
- `new EventSource('/api/events')` in `<script>`
- Parse event JSON, format single line per event, append to panel
- Show: `[HH:MM:SS] tool_start: Bash`, `[HH:MM:SS] text: first 80 chars…`, `[HH:MM:SS] verify: PASS / step1, step2`

---

### Phase 4: `lobmob attach` CLI

- **Status**: pending

**`scripts/commands/attach.sh`** (new file):

1. Require `<job-name>` arg
2. Find running pod by `job-name=$TARGET` label (same logic as `connect.sh`)
3. `kubectl port-forward pod/$POD 18080:8080` in background, `trap cleanup EXIT`
4. Poll `/health` up to 5s
5. Launch `curl -sN .../api/events` in background → FIFO → format loop
6. Foreground `read` loop → `POST /api/inject`
7. On Ctrl+C/exit: kill port-forward + curl

**Event formatting** (requires `jq`; falls back to raw JSON):
- `tool_start` → cyan `[HH:MM:SS] tool  Bash`
- `text` → green `[HH:MM:SS] text  first 120 chars…`
- `verify` → yellow `[HH:MM:SS] verify  PASS` or missing steps
- `inject` → yellow `[HH:MM:SS] inject  >> message`
- `done` → green `[HH:MM:SS] DONE`
- `error` → red `[HH:MM:SS] ERROR`

Uses local port `18080` (not `8080`) so `connect` and `attach` can run simultaneously.

**Register in `scripts/lobmob`:**
- Add `attach)` to case statement (after `connect)`)
- Add to `usage()` under Connection section

---

### Phase 5: `run_task.py` cleanup

- **Status**: pending

Remove:
- `from lobster.agent import run_retry`
- `MAX_RETRIES = 2`
- The entire verify-retry `for attempt in range(...)` block (~40 lines)

Add queue creation + IPC server lifecycle around `run_task()` call:
```python
event_queue = asyncio.Queue(maxsize=500)
inject_queue = asyncio.Queue(maxsize=100)

ipc_server = None
try:
    from lobster.ipc import LobsterIPC
    ipc_server = LobsterIPC(event_queue, inject_queue)
    await ipc_server.start()
except Exception as e:
    logger.warning("IPC server unavailable (attach disabled): %s", e)

try:
    result = await run_task(config, body, event_queue=event_queue, inject_queue=inject_queue)
finally:
    if ipc_server:
        await ipc_server.stop()
```

Cost/turn accumulation now comes from `result` dict directly (no separate retry totals to merge).

The `total_turns` / `total_cost` tracking block at the bottom of `main_async()` simplifies: `total_turns = result["num_turns"]`, `total_cost = result["cost_usd"]`.

---

### Phase 6: Tests

- **Status**: pending

**New `tests/ipc-server`**: Smoke test — starts `LobsterIPC` standalone, checks `/health`, `/inject` 202/400, SSE connects. No k8s needed.

e2e-task: No changes needed. Episode loop is transparent; same observable outcomes.

Manual: `lobmob --env dev attach <job-name>` against a dev lobster during e2e run.

---

## Files Changed

| File | Change |
|------|--------|
| `src/lobster/agent.py` | Rewrite `run_task()`: ClaudeSDKClient episode loop + emit helpers; remove `_as_stream`, `query` import; deprecate `run_retry` |
| `src/lobster/run_task.py` | Remove verify-retry block; add queue creation + IPC server lifecycle |
| `src/lobster/ipc.py` | New: aiohttp IPC server (SSE + inject + health) |
| `src/lobster/prompts/continue.md` | New: continue prompt template |
| `scripts/server/lobmob-web-lobster.js` | Add proxy routes + SSE panel to dashboard |
| `scripts/commands/attach.sh` | New: port-forward + SSE stream + inject readline |
| `scripts/lobmob` | Register `attach` command + add to usage |

No Dockerfile changes needed (aiohttp already in lobster deps; `prompts/` already copied).
No k8s manifest changes needed (no new ports or volumes).

---

## Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-02-23 | ClaudeSDKClient episode loop over `run_retry()` | Retains in-session context; verification happens with full history |
| 2026-02-23 | IPC bound to 127.0.0.1:8090 | Not exposed directly; access only via Node.js proxy or port-forward |
| 2026-02-23 | Local port 18080 for attach | Allows `connect` and `attach` to run simultaneously |
| 2026-02-23 | MAX_OUTER_TURNS=5 | Matches old MAX_RETRIES=2 with room for natural multi-episode tasks |

## Gotchas

- **`ClaudeSDKClient` inner `max_turns` resets per episode** — each `client.query()` gets a fresh 50-turn budget. Intended.
- **`cost_usd` starts as `0` not `None`** — changed from current `run_task()` to allow `+=` accumulation across episodes.
- **IPC port conflict** — if :8090 is taken, `start()` raises, caught in `run_task.py` with warning. Agent runs fine without IPC.
- **Startup race** — sidecar starts simultaneously with lobster. Node.js proxy retry loop (5× × 500ms) bridges the gap.
- **MAX_OUTER_TURNS exhaustion** — after 5 episodes without verification pass, log error, return final result. `is_error` stays false unless SDK error — task marked completed/failed same as now.
- **`run_retry()` deprecation** — leave body intact, remove in follow-up. `run_task.py` simply stops calling it.

## Scratch

- The `continue.md` prompt should mirror `retry.md` structure but be framed as continuation, not retry (agent has context, just needs direction). Consider adding a section for injected operator messages.
- `inject_queue` is drained at the start of each episode. Messages sent during episode N land in episode N+1's prompt.

## Related

- [Roadmap](../roadmap.md)
- [Vault Scaling Plan](./vault-scaling.md) — lobwife API used for event logging
- [Lobster Reliability Plan](../completed/lobster-reliability.md) — superseded by this
- [Scratch Sheet](../planning-scratch-sheet.md)
