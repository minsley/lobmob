---
status: draft
tags: [infrastructure, lobsigliere, security]
maturity: design
created: 2026-02-15
updated: 2026-02-15
---
# System Maintenance Automation

## Summary

Establish regular automated audit and review cycles for security, code quality, task hygiene, and documentation freshness. Leverage lobsigliere (already deployed for failure investigation) to run proactive maintenance tasks on a schedule, rather than only reacting to failures.

## Open Questions

- [ ] Scheduling: should maintenance tasks run on a fixed cron (e.g. daily security scan, weekly code review) or be triggered by events (e.g. scan after every deploy)?
- [ ] Who runs maintenance tasks — lobsigliere (system task processor) or dedicated maintenance lobsters? Lobsigliere seems natural since it already handles system tasks
- [ ] Budget: maintenance tasks consume API credits. What's an acceptable daily/weekly budget for proactive scans? Need cost modeling
- [ ] Findings format: should audit results go into vault as markdown reports, or into a structured format (JSON, database) for programmatic processing?
- [ ] Escalation: when an audit finds issues, should it auto-create fix tasks, open GitHub issues, or just report to Discord? Different severity → different action?
- [ ] Scope: should audits cover only the lobmob codebase, or also the vault state and infrastructure?

## Current State

- **lobsigliere**: Runs system investigation tasks when lobsters fail. Creates PRs to fix lobmob code. Already has the infrastructure for autonomous code review and modification
- **Cron scripts**: task-manager, status-reporter, watchdog run on schedules via lobwife. Could add maintenance jobs alongside these
- **Manual**: Security reviews, doc updates, and code cleanup are done ad-hoc during development sessions
- **No proactive scanning**: Nothing currently checks for stale tasks, outdated docs, dependency vulnerabilities, or code quality drift

## Phases

### Phase 1: Define audit types and schedules

- **Status**: pending
- Security audit:
  - Scan for secrets in code (committed env vars, tokens, keys)
  - Check k8s RBAC and network policies for drift
  - Review dependency versions for known vulnerabilities
  - Frequency: daily or after each deploy
- Code maintenance audit:
  - Dead code detection (unused imports, unreachable functions)
  - Dockerfile drift (base image updates, dependency staleness)
  - Script lint (shellcheck on bash scripts)
  - Frequency: weekly
- Task maintenance audit:
  - Stale tasks (queued > 7 days, in-progress > 48h with no activity)
  - Orphaned branches (no associated task or PR)
  - Failed tasks with no investigation
  - Frequency: daily
- Documentation audit:
  - Outdated references (commands that no longer exist, wrong file paths)
  - Missing docs for new features (compare recent commits against doc coverage)
  - CLAUDE.md / MEMORY.md freshness
  - Frequency: weekly

### Phase 2: Implement audit task templates

- **Status**: pending
- Create vault task templates for each audit type (lobsigliere-compatible)
- Define expected output format: structured markdown report in vault (e.g. `030-reports/audits/YYYY-MM-DD-security.md`)
- Define severity levels: info (logged), warning (Discord notification), critical (auto-create fix task)
- Add audit skills to lobsigliere's skill set

### Phase 3: Schedule and integrate

- **Status**: pending
- Add audit job scheduling to lobwife daemon (APScheduler, alongside existing cron jobs)
- Or: create vault task files on schedule, let lobsigliere pick them up via normal task polling
- Wire results into Discord (Phase 2 of Discord UX plan — tier 1 for critical findings, tier 3 for routine reports)
- Add audit status to lobwife web dashboard

### Phase 4: Auto-remediation (stretch)

- **Status**: pending
- For well-defined issues (stale tasks, orphaned branches), auto-fix without human approval
- For code issues (dependency updates, dead code removal), create PRs for review
- For security issues, always escalate to human — no auto-fix
- Budget guardrails: max spend per maintenance cycle, circuit breaker if costs spike

## Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-02-15 | Use lobsigliere for maintenance tasks | Already deployed, already handles system tasks, has code access and PR creation ability |
| 2026-02-15 | Vault-based reports over database | Consistent with existing architecture, human-readable, version-controlled |

## Scratch

- Could track audit history over time to detect trends (are we accumulating tech debt? are security findings increasing?)
- shellcheck is available in the base image? If not, add to lobsigliere container
- The code maintenance audit could also check for TODO/FIXME/HACK comments and surface them
- Dependency audit could use `pip audit`, `npm audit`, or Dependabot-style checks
- Consider a "maintenance mode" where lobboss pauses task assignment while audits run (probably overkill, audits are read-mostly)
- Audit results could feed into the planning system — e.g. a weekly auto-generated "maintenance backlog" that gets reviewed in planning sessions
- The task maintenance audit overlaps with what task-manager.sh already does (stale task detection). Should consolidate or clearly delineate

## Related

- [Roadmap](../roadmap.md)
- [Scratch Sheet](../planning-scratch-sheet.md)
- [Discord UX](./discord-ux.md) — Audit findings need a notification strategy
- [Lobster Reliability](../completed/lobster-reliability.md) — Layer 3 (lobsigliere investigations) is the foundation for this
