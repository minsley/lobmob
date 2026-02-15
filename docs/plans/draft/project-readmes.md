---
status: draft
tags: [infrastructure, documentation]
maturity: design
created: 2026-02-15
updated: 2026-02-15
---
# Add README Files to Key Project Directories

## Summary

Add targeted README files to project directories where conventions aren't obvious from the code alone. READMEs should document the "how and why" that CLAUDE.md covers at a high level but that benefits from co-located detail.

## Open Questions

- [ ] Should READMEs duplicate any CLAUDE.md content, or strictly reference it? Leaning toward self-contained with links back to CLAUDE.md for broader context
- [ ] Should container README cover the full build pipeline (buildx, amd64, GHCR push) or just the Dockerfile relationships?
- [ ] Do skills need a README per directory (lobboss/, lobster/) or one at the skills/ root?

## Phases

### Phase 1: High-value directories

- **Status**: pending
- `containers/README.md` — Base image chain, build order, cross-arch conventions, how to add a new container variant
- `scripts/commands/README.md` — Sourced (not executed) convention, no `set -euo pipefail`, how to add a new CLI command, dispatcher pattern
- `skills/README.md` — Skill file format, naming conventions, how lobboss/lobster load them, how to add a new skill

### Phase 2: Secondary directories

- **Status**: pending
- `tests/README.md` — How to run tests, `check()` function pattern, e2e test usage, the "no pipes in check args" rule
- `docs/operations/README.md` — What runbooks exist, when to update them

## Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-02-15 | Skip READMEs for src/, k8s/, infra/ | CLAUDE.md already covers these well; code is relatively self-documenting |
| 2026-02-15 | Target directories where conventions are non-obvious | READMEs should earn their keep, not just exist for completeness |

## Scratch

- Could use a consistent README template across directories (title, purpose, structure, conventions, how to add new things)
- Consider whether lobster variant containers (lobster-android/, lobster-unity/) need their own READMEs once those are built out
- The scripts/commands/ README could include a table of all commands with one-line descriptions

## Related

- [Roadmap](../roadmap.md)
- [Scratch Sheet](../planning-scratch-sheet.md)
