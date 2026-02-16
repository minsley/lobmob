---
status: draft
tags: [infrastructure, ui, discord]
maturity: research
created: 2026-02-15
updated: 2026-02-15
---
# Cost Tracking & Reporting

## Summary

Build a cost tracking system that captures token usage, API spend, and infrastructure costs, then surfaces them through Discord slash commands and the web dashboard. The data storage strategy for cost data depends on broader vault scaling decisions — whether we stay git-only or introduce a database.

## Open Questions

- [ ] Data pipeline: how do lobboss and lobsters report token usage? Push to a central accumulator (lobwife?) on each API call, or parse structured logs after the fact?
- [ ] Storage: accumulate in-memory on lobwife (fast but volatile), persist to vault files (git-native but awkward for time-series), or use a database (cleanest but new infrastructure)?
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

## Storage Options

### Option A: lobwife accumulator
- lobboss and lobsters push cost events to lobwife HTTP API
- lobwife maintains running totals in memory, persists to PVC (JSON or SQLite)
- Slash commands query lobwife's API
- Pros: lobwife is already persistent with state management, already has per-task tracking via token broker
- Cons: another responsibility on lobwife, single point of failure for cost data

### Option B: Vault reports
- Cost data written to vault markdown files (e.g. `030-reports/costs/2026-02-15.md`)
- Slash commands parse vault files
- Pros: git-native, human-readable, version-controlled
- Cons: awkward for time-series queries, slow to aggregate across date range

### Option C: Database
- If vault scaling introduces a database (SQLite, PostgreSQL), cost data goes there
- Cleanest for time-series queries, aggregation, retention policies
- Pros: proper data model, fast queries
- Cons: depends on vault scaling decisions, new infrastructure

## Phases

### Phase 1: Cost event capture

- **Status**: pending
- Define cost event schema: task_id, model, input_tokens, output_tokens, cost_usd, timestamp
- Instrument lobboss and lobster Agent SDK calls to emit cost events
- Decide on transport: HTTP push to lobwife, or structured log lines parsed later

### Phase 2: Storage and aggregation

- **Status**: pending
- Implement chosen storage backend (depends on vault scaling decisions)
- Per-task totals, daily rollups, model breakdowns
- Retention policy

### Phase 3: Discord and web UI

- **Status**: pending
- Implement `/costs`, `/costs day|week|month`, `/task cost <id>` slash commands
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
- [Vault Scaling](./vault-scaling.md) — Storage strategy depends on database decisions
- [System Maintenance Automation](./system-maintenance-automation.md) — Cost anomalies could trigger maintenance alerts
