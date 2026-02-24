---
status: draft
tags: [lobster, agent-sdk, ipc, attach]
maturity: ready
created: 2026-02-23
updated: 2026-02-24
---
# Multi-turn Lobster Execution + Attach/Inject

## Summary

Lobsters currently use one-shot `query()`: the agent runs to completion, then we verify and retry from scratch if steps are missing. Switching to episodic multi-turn via `ClaudeSDKClient` eliminates context loss on retry, moves verification between episodes (agent has full history when continuing), and enables mid-task injection from operators or lobboss via a new `lobmob attach` command.

Injections interrupt the current episode immediately (at the next tool-use boundary), similar to how Claude Code lets users press Escape and provide additional instructions. The agent gets the full conversation history plus the operator's guidance when it continues.

## Open Questions

- [ ] Should `MAX_OUTER_TURNS` be configurable per task (e.g. via task metadata)?
- [ ] Should injections from `lobmob attach` be logged to the lobwife event log (via `_api_log_event`)?
- [ ] Should the SSE event panel in the dashboard persist across page refreshes (store in sessionStorage)?

## Architecture

```
run_task.py main_async()
  ├── create event_queue + inject_queue + inject_event
  ├── start LobsterIPC server (:8090, localhost only)
  ├── await agent.run_task(config, body, event_queue, inject_queue, inject_event)
  │     ├── ClaudeSDKClient.connect()  [persistent across episodes]
  │     ├── Episode 0: client.query(initial_prompt)
  │     │     ├── can_use_tool() checks inject_event before each tool
  │     │     │     └── inject_event SET → deny tool → agent stops episode
  │     │     └── receive_response() → emit events → ResultMessage
  │     ├── inject_event set? → drain queue → build inject prompt → next episode
  │     ├── else: verify_completion() → [PASS → done] [FAIL → continue]
  │     ├── Episode 1: client.query(continue_prompt or inject_prompt)
  │     │     └── ...
  │     ├── ...up to MAX_OUTER_TURNS=5
  │     └── client.disconnect()
  ├── _ensure_vault_pr() safety net  [unchanged from current]
  └── stop IPC server, PATCH API status

LobsterIPC (aiohttp, :8090)
  ├── GET  /events  → SSE stream (per-client queue fan-out)
  ├── POST /inject  → enqueue to inject_queue + set inject_event + echo to event_queue
  └── GET  /health  → {"status": "ok", "sse_clients": N}

lobmob-web-lobster.js (Node.js, :8080)
  ├── [existing endpoints unchanged]
  ├── GET  /api/events  → proxy → :8090/events
  ├── POST /api/inject  → proxy → :8090/inject
  └── dashboard HTML: SSE event panel + inject textbox added

lobmob attach <job>
  ├── kubectl port-forward pod/:8080 → localhost:8080 (same as connect)
  ├── curl -sN .../api/events → process substitution → format + print
  ├── readline loop → POST /api/inject
  ├── auto-exit on "done"/"error" event
  └── on Ctrl+C/exit: kill port-forward + curl
```

### Mid-Episode Injection Flow

The injection mechanism interrupts the agent at the next **tool-use boundary** — the
`can_use_tool` callback fires before every tool execution, providing a natural and
SDK-supported interruption point. No undocumented abort APIs needed.

```
Operator types "also update the README" in attach CLI
  → POST /inject → inject_queue.put() + inject_event.set()
  → Agent tries to use next tool (e.g. Edit)
  → can_use_tool() sees inject_event is set
  → Returns PermissionResultDeny("Operator has provided new guidance. Wrap up.")
  → Agent receives denial, finishes current episode (produces ResultMessage)
  → Episode loop: inject_event was set → skip verification
  → Drain inject_queue, build inject prompt with operator messages
  → Next episode: client.query(inject_prompt)
  → Agent continues with full history + operator guidance
```

**Latency**: The injection takes effect at the next tool call. During pure text generation
(no tool use), there's no interruption point — but lobsters are heavily tool-driven (Read,
Edit, Bash), so typical latency is seconds, not minutes. Worst case: agent is mid-thought
between tool calls; injection lands after that thought completes and the next tool is
attempted.

## Phases

### Phase 1: Multi-turn Episode Loop (`agent.py`)

- **Status**: pending

**Imports — add, remove:**
```python
# ADD
import asyncio
from claude_agent_sdk import ClaudeSDKClient, PermissionResultDeny
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
    inject_event: asyncio.Event | None = None,
) -> dict:
```

**Options construction — preserve existing block, swap `can_use_tool`:**

The existing `ClaudeAgentOptions` block stays intact (system_prompt, model, allowed_tools,
permission_mode, max_turns=50, max_budget_usd=10.0, cwd, mcp_servers, stderr). Only change:
replace `can_use_tool=create_tool_checker(...)` with the injection-aware wrapper.

```python
# MCP servers for specialized types — PRESERVE from current run_task()
mcp_servers = []
if config.lobster_type == "image-gen":
    from lobster.mcp_gemini import gemini_mcp
    mcp_servers.append(gemini_mcp)

options = ClaudeAgentOptions(
    system_prompt=system_prompt,
    model=model,
    allowed_tools=allowed_tools,
    permission_mode="acceptEdits",
    max_turns=50,
    max_budget_usd=10.0,
    cwd=os.environ.get("WORKSPACE", "/workspace"),
    can_use_tool=_make_tool_checker(config, event_queue, inject_event),  # ← wrapped
    mcp_servers=mcp_servers or None,
    stderr=lambda line: logger.debug("CLI: %s", line.rstrip()),
)
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
            if injections and not missing:
                # Injection-triggered episode (no verification failure)
                prompt = _build_inject_prompt(config.task_id, injections)
            elif missing:
                # Verification-triggered episode (may also include injections)
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

        # Check: was this episode interrupted by an injection?
        if inject_event and inject_event.is_set():
            inject_event.clear()
            await _emit(event_queue, "inject_abort", {"outer_turn": outer_turn})
            # Skip verification — go straight to next episode with injected guidance
            missing = []
            continue

        try:
            await pull_vault(config.vault_path)
        except Exception:
            pass

        missing = await verify_completion(
            config.task_id, config.lobster_type, config.vault_path
        )
        await _emit(event_queue, "verify", {"outer_turn": outer_turn, "missing": missing})

        if not missing:
            # Check for any late-arriving injections before exiting
            if inject_event and inject_event.is_set():
                inject_event.clear()
                continue
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
    """Build prompt for verification-failure continuation (may include injections)."""
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

def _build_inject_prompt(task_id: str, injections: list[str]) -> str:
    """Build prompt for operator-injection continuation (no verification failure)."""
    path = _resolve_prompt_path("inject.md")
    if path:
        tmpl = path.read_text()
        inject_str = "\n".join(f"- {m}" for m in injections)
        return tmpl.replace("{task_id}", task_id) \
                   .replace("{operator_messages}", inject_str)
    # Inline fallback
    lines = [
        f"## Operator Guidance: {task_id}",
        "",
        "The operator has interrupted with the following message(s):",
    ]
    lines += [f"- {m}" for m in injections]
    lines += [
        "",
        "Incorporate this guidance and continue your work.",
        "You were interrupted mid-task — review what you've already done,",
        "then proceed with the operator's direction in mind.",
    ]
    return "\n".join(lines)
```

**`_make_tool_checker` — wrap existing hook to emit events + check for injection:**
```python
def _make_tool_checker(
    config: LobsterConfig,
    event_queue: asyncio.Queue | None,
    inject_event: asyncio.Event | None,
):
    inner = create_tool_checker(config.lobster_type)

    async def check_tool(tool_name, tool_input, context):
        await _emit(event_queue, "tool_start", {"tool": tool_name, "input": tool_input})

        # Check for pending injection — interrupt at tool boundary
        if inject_event and inject_event.is_set():
            logger.info("Injection pending — denying tool %s to interrupt episode", tool_name)
            await _emit(event_queue, "tool_denied", {
                "tool": tool_name,
                "reason": "injection_interrupt",
            })
            return PermissionResultDeny(
                message="The operator has provided new guidance. "
                "Stop what you're doing and wrap up this turn. "
                "You will receive the operator's message in the next prompt."
            )

        return await inner(tool_name, tool_input, context)

    return check_tool
```

The deny message is carefully worded: it tells the agent to **stop and wrap up**, not to
try alternative approaches. The agent will produce a brief text response acknowledging
the interruption, the SDK emits a `ResultMessage`, and the episode loop continues to the
next iteration where it builds the inject prompt.

**`run_retry()` — mark deprecated, leave body intact.** Remove in follow-up cleanup.

**New prompt files:**
- `src/lobster/prompts/continue.md` — placeholders: `{task_id}`, `{missing_steps}`, `{operator_messages}`
- `src/lobster/prompts/inject.md` — placeholders: `{task_id}`, `{operator_messages}`

---

### Phase 2: IPC Server (`src/lobster/ipc.py`, new file)

- **Status**: pending

```python
import asyncio, json, logging, time
from aiohttp import web

HOST = "127.0.0.1"
PORT = 8090

class LobsterIPC:
    def __init__(self, event_queue, inject_queue, inject_event): ...
    async def start(self): ...   # AppRunner + TCPSite + broadcast task
    async def stop(self): ...    # cancel task, close SSE clients, cleanup runner

    async def _broadcast_loop(self):
        # await event_queue.get() unconditionally (always drain to prevent saturation)
        # fan-out: for each client, put_nowait into per-client queue (drop on full)

    async def _handle_sse(self, request):
        # Create per-client asyncio.Queue(maxsize=100)
        # Register in self._clients set
        # StreamResponse: loop get() from per-client queue, write SSE
        # Unregister on disconnect

    async def _handle_inject(self, request):
        # parse JSON body {"message": "..."}
        # inject_queue.put_nowait(message)
        # inject_event.set()           ← signal episode loop to interrupt
        # echo to event_queue
        # return 202 {"status": "queued", "interrupt": true}

    async def _handle_health(self, request):
        # {"status": "ok", "sse_clients": N}
```

**SSE fan-out uses per-client queues** to prevent slow clients from stalling the broadcast.
The broadcast loop always drains `event_queue` even when no clients are connected (prevents
queue saturation). Each SSE client gets its own bounded queue; events are dropped with a
warning for slow clients rather than blocking the fan-out.

```python
async def _broadcast_loop(self):
    while True:
        event = await self._event_queue.get()
        for client_queue in list(self._clients):
            try:
                client_queue.put_nowait(event)
            except asyncio.QueueFull:
                logger.debug("Dropping event for slow SSE client")
```

**`_handle_inject` sets `inject_event`** in addition to queuing the message. This triggers
the `can_use_tool` interrupt at the next tool boundary. The 202 response includes
`"interrupt": true` so the attach CLI knows the injection will take effect immediately
(at next tool call), not at the next episode boundary.

**Event types:**

| type | key fields |
|------|-----------|
| `turn_start` | `outer_turn` |
| `tool_start` | `tool`, `input` |
| `tool_denied` | `tool`, `reason` |
| `text` | `text`, `outer_turn` |
| `turn_end` | `outer_turn`, `inner_turns`, `cost_usd`, `is_error` |
| `verify` | `outer_turn`, `missing` |
| `inject` | `messages` (list) |
| `inject_abort` | `outer_turn` |
| `done` | `is_error`, `cost_usd` |
| `error` | `message` |

SSE format: `data: {json}\n\n`. Bound to `127.0.0.1` only.

---

### Phase 3: Sidecar Proxy (`lobmob-web-lobster.js`)

- **Status**: pending

Add `proxyToIpc(req, res, ipcPath, method)` helper:
- Proxies to `127.0.0.1:8090`
- Retries up to 5x with 500ms backoff (handles startup race)
- For SSE: pipe `proxyRes` directly into `res` to preserve streaming
- For POST: pipe `req` into `proxyReq`
- Returns 503 with `{"error": "IPC not available"}` after retries exhausted

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
- Show: `[HH:MM:SS] tool_start: Bash`, `[HH:MM:SS] text: first 80 chars...`, `[HH:MM:SS] verify: PASS / step1, step2`
- New events: `inject_abort` shown as `[HH:MM:SS] INTERRUPTED — applying operator guidance`
- New events: `tool_denied` shown as `[HH:MM:SS] tool denied: Edit (injection interrupt)`

Add inject input to dashboard HTML (below events panel):
- `<input id="inject-input" placeholder="Send guidance to lobster...">` + send button
- POST to `/api/inject` with `{"message": value}`
- Clear input on success, show confirmation flash

---

### Phase 4: `lobmob attach` CLI

- **Status**: pending

**`scripts/commands/attach.sh`** (new file):

1. Require `<job-name>` arg
2. Find running pod by `job-name=$TARGET` label (same logic as `connect.sh`)
3. `kubectl port-forward pod/$POD $LOCAL_PORT:8080` in background, `trap cleanup EXIT` (uses same `LOBMOB_CONNECT_PORT` / default `8080` as `connect`)
4. Poll `/health` up to 5s; on failure, check `/api/events` — if 503, print "IPC not available on this lobster (started without IPC server)" and exit 1
5. Launch SSE reader via process substitution: `while IFS= read -r line; do ... done < <(curl -sN .../api/events)` (no named FIFO needed)
6. SSE reader runs in background; format loop parses JSON, prints formatted events
7. Foreground `read -rp "inject> "` loop -> `POST /api/inject`
8. **Auto-exit on done/error**: SSE format loop detects `done` or `error` event type, prints final summary, sets a flag file, and the main read loop checks flag + exits cleanly
9. On Ctrl+C/exit: kill port-forward + curl via trap

**Event formatting** (requires `jq`; falls back to raw JSON):
- `tool_start` -> cyan `[HH:MM:SS] tool  Bash`
- `tool_denied` -> yellow `[HH:MM:SS] tool denied  Edit (injection interrupt)`
- `text` -> green `[HH:MM:SS] text  first 120 chars...`
- `verify` -> yellow `[HH:MM:SS] verify  PASS` or missing steps
- `inject` -> magenta `[HH:MM:SS] inject  >> message`
- `inject_abort` -> magenta `[HH:MM:SS] INTERRUPTED — applying guidance next episode`
- `done` -> green `[HH:MM:SS] DONE  cost=$X.XX`
- `error` -> red `[HH:MM:SS] ERROR  message`

**After sending injection**: print confirmation: `sent — will interrupt at next tool call`.

Uses same local port as `connect` (`LOBMOB_CONNECT_PORT`, default `8080`). They can't run simultaneously for the same pod, but that's fine — `attach` is a superset of `connect` for lobster targets.

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
- The `for/else` final verification check block

Add queue creation + inject event + IPC server lifecycle around `run_task()` call:
```python
event_queue = asyncio.Queue(maxsize=500)
inject_queue = asyncio.Queue(maxsize=100)
inject_event = asyncio.Event()

ipc_server = None
try:
    from lobster.ipc import LobsterIPC
    ipc_server = LobsterIPC(event_queue, inject_queue, inject_event)
    await ipc_server.start()
except Exception as e:
    logger.warning("IPC server unavailable (attach disabled): %s", e)

try:
    result = await run_task(
        config, body,
        event_queue=event_queue,
        inject_queue=inject_queue,
        inject_event=inject_event,
    )
finally:
    if ipc_server:
        await ipc_server.stop()
```

**Preserved blocks** (explicitly unchanged):
- `_setup_gh_token()` call and implementation
- `_ensure_vault_pr()` safety net — still runs after `run_task()` returns, before API PATCH
- API status PATCH (`_api_update_status` / `_api_log_event`) at end of `main_async()`
- Initial vault pull + task file read logic

Cost/turn accumulation now comes from `result` dict directly (no separate retry totals to merge).

The `total_turns` / `total_cost` tracking block at the bottom of `main_async()` simplifies: `total_turns = result["num_turns"]`, `total_cost = result["cost_usd"]`. The "Final totals (including retries)" conditional log block can be removed since there's no separate retry tracking.

---

### Phase 6: Tests

- **Status**: pending

**New `tests/ipc-server`**: Smoke test — starts `LobsterIPC` standalone, checks `/health`, `/inject` 202/400, SSE connects. Verify inject response includes `"interrupt": true`. No k8s needed.

**New `tests/episode-loop`**: Unit test with mocked `ClaudeSDKClient`. Covers:
- (a) Pass on first episode — verify loop exits after 1 iteration
- (b) Fail then pass — verify `_build_continue_prompt` called with missing steps, loop exits after 2
- (c) MAX_OUTER_TURNS exhaustion — verify all 5 episodes run, result returned without `is_error`
- (d) SDK error on episode 2 — verify loop breaks, `is_error=True`, `cost_usd` includes both episodes
- (e) Inject drain at episode boundary — enqueue messages before episode 2, verify they appear in continue prompt
- (f) **Mid-episode injection abort** — set `inject_event` during episode 0, verify:
  - `can_use_tool` returns `PermissionResultDeny`
  - Episode ends (ResultMessage received)
  - `inject_event` is cleared
  - Verification is skipped
  - Next episode uses `_build_inject_prompt` (not `_build_continue_prompt`)
  - `inject_abort` event emitted
- (g) **Injection at verification-pass boundary** — set `inject_event` after verification passes, verify loop continues instead of breaking

Mock strategy: patch `ClaudeSDKClient` to yield canned `AssistantMessage` + `ResultMessage` sequences. Patch `verify_completion` to return configurable missing lists. Patch `pull_vault` as no-op. For (f), mock `can_use_tool` to observe deny behavior by simulating the tool check → deny → ResultMessage flow.

e2e-task: No changes needed. Episode loop is transparent; same observable outcomes.

Manual: `lobmob --env dev attach <job-name>` against a dev lobster during e2e run. Test injection mid-task and observe interruption latency.

---

## Files Changed

| File | Change |
|------|--------|
| `src/lobster/agent.py` | Rewrite `run_task()`: ClaudeSDKClient episode loop + inject interrupt via `can_use_tool` + emit helpers; remove `_as_stream`, `query` import; deprecate `run_retry`; preserve mcp_servers + all options |
| `src/lobster/run_task.py` | Remove verify-retry block; add queue/event creation + IPC server lifecycle; preserve safety net + API PATCH |
| `src/lobster/ipc.py` | New: aiohttp IPC server (SSE with per-client queues + inject with interrupt signal + health) |
| `src/lobster/prompts/continue.md` | New: continue prompt template (verification failure) |
| `src/lobster/prompts/inject.md` | New: inject prompt template (operator interruption) |
| `scripts/server/lobmob-web-lobster.js` | Add proxy routes + SSE panel + inject input to dashboard |
| `scripts/commands/attach.sh` | New: port-forward + SSE stream + inject readline + auto-exit |
| `scripts/lobmob` | Register `attach` command + add to usage |
| `tests/episode-loop` | New: unit test for episode loop (7 scenarios, mocked SDK) |
| `tests/ipc-server` | New: IPC smoke test |

No Dockerfile changes needed (aiohttp already in lobster deps; `prompts/` already copied).
No k8s manifest changes needed (no new ports or volumes).

---

## Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-02-23 | ClaudeSDKClient episode loop over `run_retry()` | Retains in-session context; verification happens with full history |
| 2026-02-23 | IPC bound to 127.0.0.1:8090 | Not exposed directly; access only via Node.js proxy or port-forward |
| 2026-02-23 | `attach` shares port with `connect` (no separate port) | Same pod endpoint; dashboards may be exposed directly soon, making local port-forward less relevant |
| 2026-02-23 | MAX_OUTER_TURNS=5 | Matches old MAX_RETRIES=2 with room for natural multi-episode tasks |
| 2026-02-23 | Per-client SSE queues | Prevents slow clients from stalling broadcast loop |
| 2026-02-23 | Process substitution over named FIFO | Cleaner cleanup, no stale FIFO files on abnormal exit |
| 2026-02-23 | Shared $10 budget across episodes | SDK accumulates cost on persistent client; old model was $10+2x$2=$14 effective cap |
| 2026-02-24 | Mid-episode abort via `can_use_tool` deny | SDK-supported interrupt point; no undocumented abort API needed. Fires at every tool boundary, which is frequent for lobsters |
| 2026-02-24 | Separate inject.md vs continue.md prompts | Different framing: injection = "operator redirected you" vs continue = "verification found gaps". Agent needs different context for each |
| 2026-02-24 | Injection-aborted episodes skip verification | Agent was interrupted — its work is incomplete by definition. Verify after the next (non-aborted) episode instead |

## Gotchas

- **`ClaudeSDKClient` inner `max_turns` resets per episode** — each `client.query()` gets a fresh 50-turn budget. Intended.
- **`max_budget_usd` is shared across episodes** — SDK tracks cumulative spend on the persistent client. Effective budget drops from $14 (old: $10 initial + 2x$2 retry) to $10 total. Increase `max_budget_usd` if lobsters consistently exhaust budget mid-episode.
- **`cost_usd` starts as `0` not `None`** — changed from current `run_task()` to allow `+=` accumulation across episodes.
- **`session_id` overwrites per episode** — `ResultMessage.session_id` is captured each episode; final value wins. Should be the same across episodes on one client, but only the last is stored.
- **IPC port conflict** — if :8090 is taken, `start()` raises, caught in `run_task.py` with warning. Agent runs fine without IPC.
- **Startup race** — sidecar starts simultaneously with lobster. Node.js proxy retry loop (5x x 500ms) bridges the gap.
- **MAX_OUTER_TURNS exhaustion** — after 5 episodes without verification pass, log error, return final result. `is_error` stays false unless SDK error — task marked completed/failed same as now. Injection-aborted episodes count toward this limit (prevents infinite inject loops).
- **`run_retry()` deprecation** — leave body intact, remove in follow-up. `run_task.py` simply stops calling it.
- **Injection latency** — interrupt fires at the next `can_use_tool` call (tool-use boundary). During pure text generation there's no interruption point. Typical latency is seconds since lobsters use tools heavily. Worst case: long text generation before next tool call.
- **Agent response to tool deny** — the deny message tells the agent to "stop and wrap up". The agent may produce 1-2 more text blocks before emitting `ResultMessage`. It should NOT try alternative tools (the deny message is specific about wrapping up). If agents consistently try workarounds, tighten the deny message or deny ALL tools once `inject_event` is set.
- **Rapid-fire injections** — multiple injections before the next tool boundary all queue up. They're drained together at the next episode start and presented as a list. `inject_event` only needs to be set once; subsequent sets are no-ops (already set).
- **Aborted episode cost tracking** — the aborted episode still produces a `ResultMessage` (the agent wraps up after denial), so `cost_usd` and `num_turns` are tracked. No cost is lost.
- **Late injection at verification pass** — if `inject_event` is set after verification passes but before the `break`, the loop catches it and continues to the next episode. Injections are not lost at this boundary.
- **Slow SSE clients** — per-client queues (maxsize=100) drop events for slow consumers. `attach` over kubectl port-forward adds latency but should stay within bounds for event volume.
- **IPC unavailable detection** — `attach` checks health endpoint first; if proxy returns 503 (IPC not started), prints clear error and exits rather than timing out.

## Scratch

- The `continue.md` prompt should mirror `retry.md` structure but be framed as continuation, not retry (agent has context, just needs direction).
- The `inject.md` prompt is framed as "operator interrupted you" — acknowledges the agent was mid-task and its current tool was denied. Should NOT mention verification or missing steps.
- If the deny-all-tools-on-inject approach is needed (agent tries workarounds after first deny), the simplest implementation is: once `inject_event` is set, deny every tool call until the episode ends. The event is only cleared in the episode loop, not in `can_use_tool`.
- Consider: should `inject.md` include a summary of what tools were denied? Would help agent understand where it was interrupted. Could pass last denied tool name via a `{interrupted_tool}` placeholder. Low priority.
- Future consideration: WebSocket upgrade for the SSE endpoint would allow bidirectional communication, but SSE + POST is simpler and sufficient.

## Related

- [Roadmap](../roadmap.md)
- [Vault Scaling Plan](./vault-scaling.md) — lobwife API used for event logging
- [Lobster Reliability Plan](../completed/lobster-reliability.md) — superseded by this
- [Scratch Sheet](../planning-scratch-sheet.md)
