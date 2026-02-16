# Planning System

This directory contains lobmob's roadmap, plan documents, and idea staging area.

## Structure

```
docs/plans/
  roadmap.md                — Dashboard with Dataview queries, priorities, theme index
  planning-scratch-sheet.md — Raw idea inbox and staging area
  _template.md              — Template for new plan documents
  README.md                 — You are here
  backlog/                  — Ideas promoted from scratch sheet, not yet designed
  draft/                    — Being designed, open questions unresolved
  active/                   — In progress, phases being executed
  completed/                — Done
  archive/                  — Shelved, superseded, or abandoned
```

## Lifecycle

1. **Raw ideas** go in `planning-scratch-sheet.md` first — bullet points, questions, half-formed thoughts
2. When an idea is ready to be designed, create a plan doc from `_template.md` and place it in `backlog/` or `draft/`
3. Replace the scratch sheet bullet with a markdown link to the new plan doc
4. As work progresses, move the file between directories to match its status
5. Update the frontmatter `status` field to match the directory

```
scratch sheet → backlog/ → draft/ → active/ → completed/
                                         ↘ archive/
```

## Plan Doc Format

Every plan doc uses YAML frontmatter:

```yaml
---
status: draft          # Must match directory: backlog / draft / active / completed / archive
tags: [vault, infrastructure]   # Area of work
maturity: research     # research / design / implementation
created: 2026-02-15
updated: 2026-02-15
---
```

Required sections (see `_template.md` for full structure):

- **Summary** — What and why
- **Open Questions** — Unresolved design decisions (checkboxes)
- **Phases** — Ordered implementation steps with status
- **Decisions Log** — Key choices and rationale
- **Scratch** — Ad-hoc ideas captured during work, to be refined later
- **Related** — Markdown links to roadmap, scratch sheet, and related plans

## Conventions

- **Markdown links**, not wikilinks: `[text](./path/to/doc.md)`
- **Tags** for filtering: area of work (`lobster`, `vault`, `infrastructure`, `ui`, `discord`, `self-improvement`, `lobwife`, `lobboss`) and maturity level in the `maturity` field
- **Dataview** queries in `roadmap.md` auto-populate from frontmatter — no manual index maintenance needed
- **Scratch sections** in each plan doc serve as a per-topic idea dump. Raw thoughts here get refined into open questions and phases over time
- **Cross-references**: plans link back to roadmap and scratch sheet. When a scratch item graduates, it becomes a link to the plan doc

## Session Workflow

- **Session start**: Check `roadmap.md` for active plans, pick up where you left off
- **During work**: Capture ad-hoc ideas in the relevant plan's Scratch section
- **Session end**: Update any plan docs that changed (status, phase progress, new scratch notes)
- **New ideas**: Add to `planning-scratch-sheet.md`, don't create a plan doc until it's ready to design

## Obsidian Integration

The planning system is designed to work well in Obsidian:

- **Dataview plugin** renders the roadmap queries as live tables
- **Tags** in frontmatter are searchable and filterable
- **Graph view** shows connections between plans via markdown links
- **File explorer** shows status at a glance via directory structure
