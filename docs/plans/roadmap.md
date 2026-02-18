---
tags: [meta]
updated: 2026-02-15
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

*Updated 2026-02-15*

The system is stable at v0.2.1 with core SWE/research/QA lobster types working end-to-end. The next wave of work falls into three broad tracks:

1. **Platform hardening** — Vault scaling, real-time sync, maintenance automation. Making the existing system more robust before adding complexity.
2. **New capabilities** — Lobster variants (Ghidra, Xcode, Arduino, PCB), MCP integrations, tool dependency management. Expanding what lobsters can do.
3. **User experience** — Discord UX overhaul, web dashboard improvements, WAN access. Making the system easier to interact with.

Self-improvement (autonomous failure recovery and redeployment) is a long-term research track that requires the platform to be more stable first.

---

## All Themes

Quick reference of all roadmap themes and where they stand. See [planning-scratch-sheet.md](./planning-scratch-sheet.md) for raw ideas.

| Theme | Tags | Current State |
|-------|------|---------------|
| Vault scaling & sync | `vault` | Scratch — needs design |
| Lobster variants | `lobster` | Scratch — needs research |
| MCP integrations | `lobster`, `infrastructure` | Scratch — needs research |
| System maintenance automation | `infrastructure` | Scratch — near-term |
| Lobster management (warm pools) | `lobster`, `infrastructure` | Scratch — needs design |
| Task flow improvements | `ui`, `infrastructure` | Scratch — near-term |
| Self-improvement | `self-improvement` | Scratch — long-term research |
| Discord UX | `discord`, `ui` | Scratch — needs design |
| Web UI & WAN access | `ui`, `infrastructure` | Scratch — needs design |
| Tool dependency management | `lobster` | Scratch — needs research |
| Usage analytics (catsyphon) | `infrastructure` | Scratch — needs research |
| CI/CD pipeline | `infrastructure`, `deployment` | [Draft](draft/ci-cd.md) — image builds + deploy automation |
