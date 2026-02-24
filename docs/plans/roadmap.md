---
tags: [meta]
updated: 2026-02-24
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

*Updated 2026-02-24*

The system is at v0.5.3 on DOKS with SWE/research/QA lobster types, GitHub App token broker, and the vault sync daemon (DB as source of truth, vault as human mirror). The biggest pain points now are: lobster task failures from context loss on retry (3/10 e2e failures), slow cloud-only dev iteration, and no way to intervene mid-task.

### Current priority order

1. **Local overlay** ([draft](draft/local-overlay.md)) — k3d cluster with Kustomize overlay for local dev. Shortens the feedback loop from "cross-build + push + deploy to DOKS" to "native build + k3d import". Unblocks fast iteration on multi-turn and lobster variants. 4 phases, mostly infra scripting.

2. **Multi-turn lobster** ([draft](draft/multi-turn-lobster.md)) — Replace one-shot `query()` + verify-retry with persistent `ClaudeSDKClient` episode loop. Verification happens in-session (agent keeps context). Operator injection via `lobmob attach` interrupts at the next tool boundary, similar to Claude Code's Escape flow. Directly addresses the #1 lobster failure mode.

3. **Vault scaling P4-P6** ([active](active/vault-scaling.md), P1-P3 complete) — Cost/audit tables (P4), git workflow cleanup (P5), Obsidian Dataview views (P6). Independent phases, none blocking. P4 becomes more useful after multi-turn lands (per-episode cost accumulation gives better data).

### Broader tracks (unchanged)

- **New capabilities** — Lobster variants (Ghidra, Xcode, Arduino, PCB, ROS2, Home Assistant), MCP integrations. Unblocked by local overlay for experimentation without cloud cost.
- **User experience** — Discord UX overhaul, web dashboard, WAN access. Task flow improvements depend on vault-scaling P2 API (done).
- **Infrastructure** — CI/CD pipeline, system maintenance automation. Draft plans ready.
- **Self-improvement** — Autonomous failure recovery. Long-term research track.

---

## All Themes

Quick reference of all roadmap themes and where they stand. See [planning-scratch-sheet.md](./planning-scratch-sheet.md) for raw ideas.

| Theme | Tags | Current State | Priority |
|-------|------|---------------|----------|
| Local overlay | `infrastructure`, `local` | [Draft](draft/local-overlay.md) — k3d + Kustomize overlay | **Next up** |
| Multi-turn lobster | `lobster`, `agent-sdk` | [Draft](draft/multi-turn-lobster.md) — episode loop + attach/inject | **Next up** |
| Vault scaling & sync | `vault`, `lobwife` | [Active](active/vault-scaling.md) — P1-P3 complete (v0.5.3), P4-P6 pending | Paused |
| Lobster variants | `lobster` | [Draft](draft/lobster-variants.md) — overview + 8 individual variant plans | After local overlay |
| CI/CD pipeline | `infrastructure`, `deployment` | [Draft](draft/ci-cd.md) — image builds + deploy automation | Draft ready |
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
