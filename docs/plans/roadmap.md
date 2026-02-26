---
tags: [meta]
updated: 2026-02-25
---
# lobmob Roadmap

## How This Works

Plans live in subdirectories by status:

| Directory | Meaning |
|-----------|---------|
| `backlog/` | Promoted from scratch sheet, not yet designed |
| `draft/` | Being designed, open questions unresolved |
| `active/` | In progress, phases being executed |
| `completed/` | Done |
| `archive/` | Shelved, superseded, or abandoned |

Each plan doc has frontmatter with `status`, `tags`, `maturity`, and dates. Move files between directories when status changes. The Dataview queries below auto-populate from that metadata.

**Conventions:**
- New ideas go in [planning-scratch-sheet.md](./planning-scratch-sheet.md) first
- When an idea is ready to design, create a plan from [_template.md](./_template.md) in `backlog/` or `draft/`
- Link the scratch sheet item to the new plan doc
- Use markdown links (not wikilinks) for cross-references
- Tags: area of work (`lobster`, `vault`, `infrastructure`, `ui`, `discord`, `self-improvement`, `lobwife`, `lobboss`) and `maturity` field (`research` / `design` / `implementation`)

---

## Active Plans

```dataview
TABLE
  maturity AS "Maturity",
  tags AS "Tags",
  file.mtime AS "Updated"
FROM "plans/active"
SORT file.mtime DESC
```

## Draft Plans

```dataview
TABLE
  maturity AS "Maturity",
  tags AS "Tags",
  file.mtime AS "Updated"
FROM "plans/draft"
SORT file.mtime DESC
```

## Backlog

```dataview
TABLE
  maturity AS "Maturity",
  tags AS "Tags",
  file.mtime AS "Updated"
FROM "plans/backlog"
SORT file.mtime DESC
```

## Completed

```dataview
TABLE
  maturity AS "Maturity",
  tags AS "Tags",
  updated AS "Completed"
FROM "plans/completed"
SORT updated DESC
```

## Archived

```dataview
TABLE
  maturity AS "Maturity",
  tags AS "Tags",
  file.mtime AS "Updated"
FROM "plans/archive"
SORT file.mtime DESC
```

---

## Priorities & Narrative

*Updated 2026-02-26*

The system is at v0.6.0 on DOKS with SWE/research/QA lobster types, GitHub App token broker, vault sync daemon, local k3d overlay, and multi-turn lobster execution. v0.6.0 was validated on DOKS dev: e2e 10/10, review-prs auto-merge, attach SSE streaming all passing. Five staging bugs were found and fixed during the dev test (kubectl missing from lobwife, invalid job field selector, VAULT_PATH mismatch, gh broker wrapper, Python 3.9 compat).

### Current priority order

1. **Project READMEs** ([active](active/project-readmes.md)) — 5 READMEs in progress. Low-effort, high-documentation-value. Can interleave with other work.

2. **Test framework** ([draft](draft/test-framework.md)) — 8 phases: cleanup dead tests, shared test lib, pytest foundation + new unit tests for safety-critical code (hooks.py, verify.py, sync), test runner, lobster test path safety, CI lint+unit jobs, variant test conventions. Lock in coverage now before variant expansion adds surface area. Phases 1-4 are small (1-2 sessions); CI phases feed into CI/CD plan.

3. **Vault scaling P4-P6** ([active](active/vault-scaling.md), P1-P3 complete) — Cost/audit tables (P4), git workflow cleanup (P5), Obsidian Dataview views (P6). Independent phases, none blocking. P4 becomes more useful now that multi-turn tracks per-episode costs.

### Broader tracks

- **New capabilities** — Lobster variants (Ghidra, Xcode, Arduino, PCB, ROS2, Home Assistant), MCP integrations. Unblocked by local overlay for experimentation without cloud cost. Test framework Phase 8 establishes the test convention that variant plans reference.
- **User experience** — Discord UX overhaul, web dashboard, WAN access. Task flow improvements depend on vault-scaling P2 API (done).
- **Infrastructure** — CI/CD pipeline (test framework Phase 6 is a prerequisite for CI/CD Phase 2), system maintenance automation. Draft plans ready.
- **Self-improvement** — Autonomous failure recovery. Long-term research track.

---

## All Themes

Quick reference of all roadmap themes and where they stand. See [planning-scratch-sheet.md](./planning-scratch-sheet.md) for raw ideas.

| Theme | Tags | Current State | Priority |
|-------|------|---------------|----------|
| Local overlay | `infrastructure`, `local` | [Completed](completed/local-overlay.md) — v0.6.0 | Done |
| Multi-turn lobster | `lobster`, `agent-sdk` | [Completed](completed/multi-turn-lobster.md) — v0.6.0 | Done |
| Vault scaling & sync | `vault`, `lobwife` | [Active](active/vault-scaling.md) — P1-P3 complete (v0.5.3), P4-P6 pending | Paused |
| Lobster variants | `lobster` | [Draft](draft/lobster-variants.md) — overview + 8 individual variant plans | After local overlay |
| CI/CD pipeline | `infrastructure`, `deployment` | [Draft](draft/ci-cd.md) — image builds + deploy automation | Draft ready |
| Test framework & CI integration | `infrastructure`, `testing` | [Draft](draft/test-framework.md) — 8 phases: cleanup, shared lib, pytest + safety tests, runner, CI jobs, variant conventions | **Next up** |
| Cost tracking | `lobwife`, `infrastructure` | [Draft](draft/cost-tracking.md) — depends on vault-scaling P4 | Blocked |
| System maintenance automation | `infrastructure` | [Draft](draft/system-maintenance-automation.md) | Draft ready |
| Task flow improvements | `ui`, `infrastructure` | [Draft](draft/task-flow-improvements.md) — web task entry, depends on vault-scaling P2 API (done) | Draft ready |
| Discord UX | `discord`, `ui` | [Draft](draft/discord-ux.md) — slash commands, single channel | Draft ready |
| Lobster management (warm pools) | `lobster`, `infrastructure` | Scratch — needs design | Backlog |
| MCP integrations | `lobster`, `infrastructure` | Scratch — needs research | Backlog |
| Tool dependency management | `lobster` | Scratch — needs research | Backlog |
| Web UI & WAN access | `ui`, `infrastructure` | Scratch — needs design | Backlog |
| Usage analytics (catsyphon) | `infrastructure` | Scratch — needs research | Backlog |
| Self-improvement | `self-improvement` | Scratch — long-term research | Long-term |
| Project READMEs | `docs` | [Active](active/project-readmes.md) — 5 READMEs in progress | Active |
