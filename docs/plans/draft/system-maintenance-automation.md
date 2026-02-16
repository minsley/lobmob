---
status: draft
tags: [infrastructure, lobsigliere, security]
maturity: design
created: 2026-02-15
updated: 2026-02-16
---
# System Maintenance Automation

## Summary

Establish regular automated audit and review cycles for security, code quality, task hygiene, documentation freshness, and infrastructure health. Three tiers of tooling: deterministic shell scripts for infra health, purpose-built scanners (trivy, shellcheck) for known vulnerability classes, and LLM-driven audits for code review and documentation quality. Results stored as vault markdown reports with Dataview-queryable frontmatter.

## Open Questions

- [x] Scheduling: cron or event-triggered? **Resolved: cron-only for v1**
- [x] Who runs them? **Resolved: CronJobs with purpose-built images (not lobsigliere)**
- [x] Budget? **Resolved: $5/audit cap for LLM-driven audits. Deterministic checks have no API cost**
- [x] Findings format? **Resolved: vault markdown with structured frontmatter + Dataview overview. Once [vault scaling](../active/vault-scaling.md) Phase 4 lands, findings also stored in `audit_findings` DB table for fast queries**
- [x] Escalation? **Resolved: severity-tiered (info/warning/critical)**
- [x] Scope? **Resolved: codebase + vault + infrastructure**
- [x] Trivy deployment? **Resolved: `aquasec/trivy` image directly, CronJob, scans GHCR images + k8s manifests + Terraform. Unprivileged, no docker socket needed**
- [ ] Audit report vault location: `030-reports/audits/` with date-based filenames? Or per-audit-type subdirectories?
- [ ] lobmob-audit-agent base image: use lobmob-base (has Agent SDK already) stripped down, or build a new minimal image from scratch?
- [ ] GHCR auth for trivy: reuse existing GitHub App token via lobwife broker, or separate read-only PAT?

## Current State

- **lobsigliere**: Runs system investigation tasks when lobsters fail. Has broad k8s RBAC and SSH access for development shell. Not suitable for routine audit CronJobs due to growing scope and over-privileged image
- **Cron scripts**: task-manager, status-reporter, watchdog run via lobwife daemon (APScheduler)
- **No proactive scanning**: Nothing currently checks for stale tasks, outdated docs, dependency vulnerabilities, container CVEs, or k8s misconfigurations

## Container Images

| Image | Purpose | Contents | Custom? |
|-------|---------|----------|---------|
| `lobmob-auditor` | Deterministic health checks, linting | Alpine + kubectl, git, curl, jq, shellcheck, pip audit, npm audit | Yes (new) |
| `aquasec/trivy` | Image + IaC vulnerability scanning | Trivy CLI | No (upstream) |
| `lobmob-audit-agent` | LLM-driven code/doc review | Minimal base + Agent SDK, Python, vault access | Yes (new) |

- `lobmob-auditor`: runs infra health checks and code linting. No Agent SDK, no SSH, minimal footprint
- `aquasec/trivy`: used as-is from upstream. Scans GHCR images for CVEs, scans k8s manifests and Terraform for misconfigurations. Only fork into `lobmob-trivy` if we need lobmob-specific customization
- `lobmob-audit-agent`: purpose-built for LLM audits. Has Agent SDK for code review and doc analysis, but none of lobsigliere's development shell extras (SSH, broad tooling)

## Audit Types

### Deterministic checks (lobmob-auditor CronJob)

| Check | What it checks | Frequency |
|-------|---------------|-----------|
| Pod health | CrashLoopBackOff, NotReady nodes, OOMKilled containers | Every 5-15 min |
| Resource usage | PVC disk usage, node CPU/memory pressure | Hourly |
| Certificate/token expiry | GitHub App token validity, TLS cert expiry | Daily |
| Image freshness | Running image digests vs. latest in GHCR | Daily |
| Bash lint | shellcheck on all scripts in scripts/ | Daily |
| Dependency audit | pip audit + npm audit on requirements and package.json | Daily |

### Vulnerability scanning (aquasec/trivy CronJob)

| Scan | What it checks | Frequency |
|------|---------------|-----------|
| Container images | CVEs in OS packages and language deps across all GHCR images (base, lobboss, lobster, lobwife, lobsigliere) | Daily |
| K8s manifests | Misconfigurations in k8s/overlays/ (RBAC, security contexts, resource limits) | Daily |
| Terraform | Misconfigurations in infra/ (insecure defaults, exposed resources) | Daily |
| Dockerfiles | Best practice violations in containers/ | Daily |

Trivy scans GHCR images directly via registry API (no docker socket). Needs `read:packages` auth. Cache vulnerability DB on a PVC or emptyDir to avoid re-downloading.

### LLM-driven audits (lobmob-audit-agent CronJob)

| Audit | What it checks | Frequency |
|-------|---------------|-----------|
| Security review | Novel patterns, unsafe code, OWASP concerns beyond what deterministic tools catch | Weekly |
| Code maintenance | Dead code, architectural drift, inconsistent patterns | Weekly |
| Task hygiene | Stale tasks (queued >7d, in-progress >48h), orphaned branches, failed with no investigation | Daily |
| Documentation | Outdated references, missing docs for new features, CLAUDE.md/MEMORY.md freshness | Weekly |

$5/audit budget cap. Task hygiene daily, code/docs/security weekly.

## Escalation Tiers

| Severity | Vault | Discord | Auto-action |
|----------|-------|---------|-------------|
| **Info** | Report only | None | None |
| **Warning** | Report | Notification in `#lobmob` (no mention) | None — human decides |
| **Critical** | Report | Notification with @user mention | Auto-create fix task via lobwife API for lobsigliere |

No GitHub issues from audits at this time.

## Phases

### Phase 1: Infrastructure health checks (deterministic)

- **Status**: pending
- Build `lobmob-auditor` image (Alpine + kubectl, shellcheck, pip audit, npm audit, jq, curl, git)
- Shell scripts for pod health, resource usage, image freshness
- shellcheck on all bash scripts in scripts/
- pip audit + npm audit on dependency files
- Output: vault reports in `030-reports/audits/` with structured frontmatter
- Discord notifications for warning+ findings
- K8s CronJob manifests in k8s/base/

### Phase 2: Trivy vulnerability scanning

- **Status**: pending
- CronJob using `aquasec/trivy` image directly
- Scan all 5 GHCR images (base, lobboss, lobster, lobwife, lobsigliere) nightly
- Scan k8s manifests (`trivy config k8s/overlays/prod/`) and Terraform (`trivy config infra/`)
- Scan Dockerfiles (`trivy config containers/`)
- Cache trivy DB on volume (emptyDir or small PVC)
- GHCR auth via k8s Secret (GitHub PAT with `read:packages` or broker token)
- Output: vault report with CVE summary and severity counts
- Discord notification for HIGH/CRITICAL findings

### Phase 3: LLM-driven audits

- **Status**: pending
- Build `lobmob-audit-agent` image (minimal base + Agent SDK, Python, vault access)
- Create audit skill templates for: security review, code maintenance, task hygiene, doc review
- K8s CronJobs: task hygiene daily, security/code/docs weekly
- $5/audit budget cap via token budget in agent config
- Output: vault reports with structured findings. Push findings to lobwife API (`POST /api/v1/audits`) once [vault scaling](../active/vault-scaling.md) Phase 4 lands
- Auto-create fix tasks for critical findings via lobwife API (`POST /api/v1/tasks`)

### Phase 4: Reporting and overview

- **Status**: pending
- **Depends on**: [vault scaling](../active/vault-scaling.md) Phase 4 (audit_findings table) and Phase 6 (Obsidian views)
- Dataview overview page in vault: audit history, severity trends, recent findings by type (powered by DB-synced markdown)
- Aggregate dashboard on lobboss web UI — queries lobwife API (`GET /api/v1/audits`) (stretch)
- Track finding resolution over time via `audit_findings.resolved_at` and linked fix task status

## Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-02-15 | Purpose-built CronJob images, not lobsigliere | Lobsigliere is growing into a dev shell with broad access. Audit images should be minimal and purpose-scoped |
| 2026-02-15 | Three-tier tooling: scripts, scanners, LLM | Each tool class has different strengths. Deterministic for known patterns, LLM for novel analysis |
| 2026-02-15 | Use aquasec/trivy directly | No need for custom image unless lobmob-specific customization is required |
| 2026-02-15 | Trivy CLI in CronJob, not Operator | Operator is overkill for 2-5 node cluster with 4-5 images |
| 2026-02-15 | shellcheck is a no-brainer | Significant bash codebase, catches real bugs deterministically, zero API cost |
| 2026-02-15 | Daily task/security audits, weekly code/docs | Balances coverage with cost. Even daily may be excessive at current project size |
| 2026-02-15 | Severity-tiered escalation, no GitHub issues | Vault tasks + Discord notifications. Keep it internal |
| 2026-02-15 | Cron-only scheduling for v1 | Event triggers (post-deploy hooks) can come later |
| 2026-02-15 | $5/audit budget cap | Sensible default for LLM audits. Deterministic checks have no API cost |
| 2026-02-15 | Vault markdown reports with Dataview | Consistent with architecture. **Update**: once vault scaling Phase 4 lands, findings also go to `audit_findings` DB table for fast queries. Vault reports remain for Obsidian browsing |

## Scratch

- Could track audit findings over time to detect trends (accumulating tech debt? increasing CVEs?)
- Audit frequency should scale with activity — if no commits this week, skip code maintenance audit
- As the project grows, consider GitHub Advanced Security or Dependabot alongside or replacing LLM security audits
- The task hygiene audit overlaps with task-manager stale task detection — consolidate or clearly delineate. Note: task-manager is being rewritten in Python as part of [vault scaling](../active/vault-scaling.md) Phase 2.6
- `lobmob-auditor` could also run pre-deploy validation (dry-run manifests, validate Terraform) as an event-triggered check later
- trivy can output SARIF format for integration with GitHub Security tab if we ever want that
- Consider running trivy on PR branches in CI (GitHub Actions) in addition to nightly cluster scans
- lobmob-audit-agent could share a base with lobster but strip out non-essential tools

## Related

- [Roadmap](../roadmap.md)
- [Scratch Sheet](../planning-scratch-sheet.md)
- [Discord UX](./discord-ux.md) — Audit findings use the notification tier system
- [Vault Scaling](../active/vault-scaling.md) — Phase 4 adds `audit_findings` DB table and API. Fix tasks created via `POST /api/v1/tasks`
- [Cost Tracking](./cost-tracking.md) — Audit spend should be tracked alongside task spend via cost_events
- [Lobster Reliability](../completed/lobster-reliability.md) — Layer 3 (lobsigliere investigations) is the foundation
