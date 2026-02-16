---
status: draft
tags: [infrastructure, ui, discord]
maturity: research
created: 2026-02-15
updated: 2026-02-16
---
# Cost Tracking & Reporting

## Summary

Build a cost tracking system that captures token usage, API spend, and infrastructure costs, then surfaces them through Discord slash commands and the web dashboard. The data storage strategy for cost data depends on broader vault scaling decisions — whether we stay git-only or introduce a database.

## Open Questions

- [x] Data pipeline: how do lobboss and lobsters report token usage? **Resolved: HTTP push to lobwife API (`POST /api/v1/costs`) after each Agent SDK `query()` call. Uses shared `lobwife_client.py`**
- [x] Storage: accumulate in-memory on lobwife (fast but volatile), persist to vault files (git-native but awkward for time-series), or use a database? **Resolved: Option C — SQLite `cost_events` table on lobwife. See [vault scaling](../active/vault-scaling.md) Phase 4**
- [ ] Granularity: per-task totals are essential. Per-model breakdowns? Per-tool-call? Hourly/daily rollups?
- [ ] Infrastructure costs: include DO resource spend (node hours, storage)? This would need DO API integration. Or keep it API-token-only for v1?
- [ ] Retention: how far back should cost data be queryable? 30 days? 90 days? Indefinite?
- [ ] Budget alerts: should there be a daily/weekly spend cap with automatic warnings or task throttling?
- [ ] Digest: opt-in daily morning summary ("Yesterday: $X spent, Y tasks completed") posted to Discord?

## Discord Commands (deferred from Discord UX plan)

```
/costs                  — Summary of all token and DO resource spend
/costs day              — Last 24 hours
/costs week             — Last 7 days
/costs month            — Last month
/task cost <task-id>    — Cost info for a specific task
```

## Storage — Decided

**Option C: SQLite database on lobwife** (decided via [vault scaling](../active/vault-scaling.md)).

- `cost_events` table: task_id (FK to tasks), model, input_tokens, output_tokens, cost_usd, created_at
- Indexes on `cost_events(task_id)` and `cost_events(created_at)` for fast queries
- API endpoints: `POST /api/v1/costs`, `GET /api/v1/costs`, `GET /api/v1/costs/summary`
- lobboss and lobsters push events via shared `lobwife_client.py` after each `query()` call
- Vault sync daemon (vault scaling Phase 3) can write periodic cost summary files for Obsidian browsing
- Depends on vault scaling Phase 4 for table creation and API endpoints

## Phases

### Phase 1: Cost event capture

- **Status**: pending
- **Depends on**: [vault scaling](../active/vault-scaling.md) Phase 4 (cost_events table + API endpoints)
- Schema: task_id (FK), model, input_tokens, output_tokens, cost_usd, created_at
- Instrument lobboss and lobster Agent SDK `query()` calls to push cost events via `lobwife_client.py`
- Transport: HTTP POST to lobwife `/api/v1/costs`

### Phase 2: Storage and aggregation

- **Status**: pending
- SQLite `cost_events` table (created in vault scaling Phase 4)
- Per-task totals, daily rollups, model breakdowns via SQL aggregation
- Retention policy (DELETE where created_at < cutoff, or archive to vault)

### Phase 3: Discord and web UI

- **Status**: pending
- **Depends on**: [discord UX](./discord-ux.md) Phase 1 (slash command infrastructure)
- Implement `/costs`, `/costs day|week|month`, `/task cost T42` slash commands
- Slash command handlers query lobwife API (`GET /api/v1/costs/summary`, `GET /api/v1/costs?task_id=42`)
- Add cost summary to lobboss web dashboard
- Optional: daily digest message

### Phase 4: Budget alerts and throttling (stretch)

- **Status**: pending
- Configurable daily/weekly spend caps
- Warning notifications to Discord when approaching cap
- Optional: auto-pause task assignment when cap is hit

## Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-02-16 | SQLite cost_events table on lobwife (Option C) | Vault scaling introduces SQLite. Cleanest for time-series queries and aggregation. No new infrastructure |
| 2026-02-16 | HTTP push via lobwife_client.py | Shared client handles retries. Push after each query() call. Simpler than log parsing |

## Scratch

- catsyphon (`github.com/kulesh/catsyphon`) from the scratch sheet could provide insight into Claude API usage patterns — worth researching as an alternative or complement to custom cost tracking
- Current structured logging (`src/common/logging.py`) already logs token counts per API call. Could backfill historical data from pod logs if needed
- Per-model pricing table is already in the logging module (Opus/Sonnet/Haiku rates). Keep this in sync with Anthropic's pricing
- Cost tracking is also useful for lobster reliability decisions — if a task costs $X in retries, that's signal for root cause investigation
- DO infrastructure costs could be pulled from the DO API billing endpoints, but this is a different beast from API token costs. Maybe v2

## Related

- [Roadmap](../roadmap.md)
- [Scratch Sheet](../planning-scratch-sheet.md)
- [Discord UX](./discord-ux.md) — Cost slash commands originate here
- [Vault Scaling](../active/vault-scaling.md) — Storage strategy depends on database decisions
- [System Maintenance Automation](./system-maintenance-automation.md) — Cost anomalies could trigger maintenance alerts
