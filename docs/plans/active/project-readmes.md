---
status: active
tags: [infrastructure, documentation]
maturity: implementation
created: 2026-02-15
updated: 2026-02-16
---
# Add README Files to Key Project Directories

## Summary

Add targeted README files to project directories where conventions aren't obvious from the code alone. READMEs should be self-contained (usable without reading CLAUDE.md first) but link back to CLAUDE.md for broader project context. Focus on directories where non-obvious conventions exist — sourced vs executed scripts, base image chains, skill file formats, test assertion patterns.

## Open Questions

- [x] Should READMEs duplicate any CLAUDE.md content, or strictly reference it? **Resolved: self-contained with links back. READMEs should be useful on their own (agents read them in-container) but avoid verbatim duplication — summarize and link**
- [x] Should container README cover the full build pipeline (buildx, amd64, GHCR push) or just the Dockerfile relationships? **Resolved: full build pipeline. The cross-arch buildx workflow is the #1 gotcha for this directory**
- [x] Do skills need a README per directory (lobboss/, lobster/) or one at the skills/ root? **Resolved: one at skills/ root. Each skill already has its own SKILL.md. Root README covers format, conventions, and lobboss vs lobster differences**

## Consistent README Structure

Each README follows this pattern:
1. **Title** — directory name + one-line purpose
2. **Structure** — table or tree of contents with one-line descriptions
3. **Conventions** — non-obvious rules and patterns
4. **How to add new things** — step-by-step for the most common addition
5. **See also** — links to CLAUDE.md, related docs

## Phases

### Phase 1: High-value directories

- **Status**: pending
- **Goal**: Cover directories where conventions are non-obvious and mistakes are costly.

**1.1 — `containers/README.md`**

Content outline:
- **Structure**: table of 5 active images (base, lobboss, lobster, lobwife, lobsigliere) + 2 placeholder variants (lobster-android, lobster-unity), with purpose and base image for each
- **Base image chain**: `lobmob-base` → lobboss, lobster, lobwife, lobsigliere. Base has Python 3.12, Node.js 22, Agent SDK, `src/common/`
- **Build conventions**:
  - Always `--platform linux/amd64` (Mac builds ARM, DOKS needs amd64)
  - Use `ARG BASE_IMAGE` + `FROM ${BASE_IMAGE}` for buildx resolution
  - Build from repo root (Dockerfile COPYs from `src/`, `scripts/`, `skills/`)
  - Push to GHCR: `ghcr.io/minsley/lobmob-{name}:latest`
  - Build order: base first, then dependents
- **Build command** example (single canonical buildx command)
- **How to add a new container variant**: create dir, Dockerfile FROM base, add to GHCR, add k8s manifests
- **Per-container notes**: lobwife and lobsigliere have entrypoint.sh and CLAUDE.md (for in-container agent sessions)

**1.2 — `scripts/README.md`**

Content outline:
- **Structure**: tree of scripts/, commands/, server/, lib/ with file counts
- **Dispatcher pattern**: `lobmob` CLI sources commands from `scripts/commands/`. `lobmob deploy` → sources `scripts/commands/deploy.sh`
- **Key convention**: commands are **sourced, not executed**. No shebang, no `set -euo pipefail` (the dispatcher sets this). Functions and variables share the dispatcher's shell
- **Commands table**: all 18 commands with one-line descriptions
- **Server scripts**: run inside k8s pods, not from the CLI. Two categories:
  - Cron scripts (run by lobwife daemon via APScheduler): task-manager, review-prs, status-reporter, flush-logs
  - Web dashboards (Node.js): lobmob-web.js (lobboss), lobmob-web-lobster.js (lobster sidecar), lobwife-web.js (lobwife)
  - Daemons (Python): lobwife-daemon.py, lobsigliere-daemon.py
- **lib/helpers.sh**: shared functions (log, warn, err, load_secrets, push_k8s_secrets, portable_sed_i)
- **Environment**: `LOBMOB_ENV=dev lobmob <cmd>` or `lobmob --env dev <cmd>`. Secrets loaded from secrets.env / secrets-dev.env
- **How to add a new CLI command**: create `scripts/commands/{name}.sh`, add function `cmd_{name}()`, update `lobmob` dispatcher case statement
- **git-credential-lobwife**: standalone credential helper, not a CLI command

**1.3 — `skills/README.md`**

Content outline:
- **Structure**: lobboss/ (10 skills) and lobster/ (11 skills), listed with one-line descriptions
- **Skill file format**: each skill is a directory containing `SKILL.md` with YAML frontmatter (`name`, `description`) followed by markdown instructions
- **How skills are loaded**: lobboss system prompt includes skill content. Skills referenced by name in agent prompts. Lobster skills loaded similarly for `run_task()`
- **lobboss vs lobster skills**:
  - lobboss: long-running, multi-turn. Task lifecycle management, Discord interaction, PR review. Judgment-heavy (evaluating requests, proposing tasks)
  - lobster: single-task, ephemeral. Code execution, verification, vault operations. Execution-heavy (following structured steps)
- **task-lifecycle as routing index**: `task-lifecycle/SKILL.md` is an index that routes to sub-skills (task-create, task-assign, task-monitor, etc.)
- **How to add a new skill**: create `skills/{agent}/{name}/SKILL.md` with frontmatter, write instructions in markdown, reference from agent prompt or parent skill

### Phase 2: Secondary directories

- **Status**: pending
- **Goal**: Cover directories with important but less frequently encountered conventions.

**2.1 — `tests/README.md`**

Content outline:
- **Structure**: list of 6 test scripts with descriptions
- **Running tests**: `LOBMOB_ENV=dev tests/{name}` (all tests target dev environment)
- **E2E test**: `LOBMOB_ENV=dev tests/e2e-task --timeout 15` — full task lifecycle (push → pickup → execute → PR → complete), 10 stages, ~5 min
- **check() function pattern**: assertion helper used by all tests. Name describes expected behavior, command is the assertion
- **Critical rules**:
  - NEVER pipe inside `check()` args — pipes run outside the check function. Use `bash -c "cmd | grep pattern"` instead
  - NEVER use `[[ ]]` inside `check()` args — `[[` is a bash keyword, not a command. Use `test` or `bash -c` instead
- **How to add a new test**: create executable bash script in tests/, use `check()` for assertions, test against dev environment

**2.2 — `docs/operations/README.md`**

Content outline:
- **Structure**: index of 5 runbooks (daily-ops, deployment, setup-checklist, testing, token-management) + web-ui guide, each with one-line description
- **When to update**: after deploying new features, changing infrastructure, or discovering operational gotchas
- **Relationship to CLAUDE.md**: operations docs cover step-by-step procedures. CLAUDE.md covers architecture and conventions. Keep both current when making changes

## Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-02-15 | Skip READMEs for src/, k8s/, infra/ | CLAUDE.md already covers these well; code is relatively self-documenting |
| 2026-02-15 | Target directories where conventions are non-obvious | READMEs should earn their keep, not just exist for completeness |
| 2026-02-16 | Self-contained READMEs with links back to CLAUDE.md | Agents read READMEs in-container without CLAUDE.md. Summarize, don't duplicate verbatim |
| 2026-02-16 | Full build pipeline in containers/README.md | Cross-arch buildx is the #1 gotcha. Dockerfile relationships alone aren't enough |
| 2026-02-16 | Single skills/README.md at root, not per-subdirectory | Each skill already has SKILL.md. Root README covers format and conventions |
| 2026-02-16 | Consistent README structure | Title, structure, conventions, how-to-add, see-also. Predictable format across all READMEs |
| 2026-02-16 | scripts/README.md at root, not per-subdirectory | One README covers dispatcher, commands, server scripts, and lib. Per-subdir READMEs would fragment the context |

## Scratch

- Consider whether lobster variant containers (lobster-android/, lobster-unity/) need their own READMEs once those are built out
- The commands table in scripts/README.md will need updating when new commands are added — note this in the README itself
- Could auto-generate the commands table from the dispatcher case statement, but manual is fine at 18 commands
- lobwife and lobsigliere already have CLAUDE.md files in their container dirs — these serve a different purpose (in-container agent context) and should coexist with containers/README.md which covers the build pipeline

## Related

- [Roadmap](../roadmap.md)
- [Scratch Sheet](../planning-scratch-sheet.md)
