---
status: draft
tags: [infrastructure, deployment, github-actions]
maturity: research
created: 2026-02-17
updated: 2026-02-17
---
# CI/CD Pipeline

## Summary

Automate image builds and deployments so code changes on main are built, pushed to GHCR, and rolled out without manual `lobmob build all` + `lobmob deploy`. Currently every deploy requires a developer to run builds locally (cross-arch amd64 on Mac), push images, then run terraform + kubectl. This is error-prone — the prod deploy today nearly went out without rebuilding images.

## Open Questions

- [ ] **Trigger strategy**: Build on every push to main? On tag/release only? On PR merge to develop for dev deploys?
- [ ] **Runner architecture**: GitHub Actions runners are amd64 (no cross-compile needed), but need GHCR push access, DO API token, and kubeconfig. How to manage secrets?
- [ ] **Terraform in CI**: Should CI run terraform apply, or just image builds + kubectl? Terraform changes are infrequent and high-risk — might be better left manual
- [ ] **Dev vs prod pipeline**: Auto-deploy to dev on develop merge, manual approval gate for prod?
- [ ] **Image tagging**: Currently `:latest` only. Should CI tag with git SHA or semver? Rollback story?
- [ ] **Build matrix**: Build all images on every change, or detect which Dockerfiles/src changed and build selectively?
- [ ] **lobwife state migration**: New schema versions need `lobwife_db.py` migration to run on startup. CI can't trigger this — it happens on pod restart. Is this sufficient?

## Phases

### Phase 1: Image builds on GitHub Actions

- **Status**: pending
- GitHub Actions workflow triggered on push to main (or tag)
- Build all 4 images (base, lobboss, lobwife, lobster) on amd64 runner
- Push to GHCR with `:latest` + git SHA tag
- No deployment — just ensures images are always current after merge

### Phase 2: Dev auto-deploy

- **Status**: pending
- On merge to develop: build images, then kubectl apply + rollout restart against dev cluster
- Requires: kubeconfig for dev DOKS in GitHub Actions secrets
- Skip terraform (infra changes remain manual)
- Run a lightweight smoke test (lobwife health check) after deploy

### Phase 3: Prod deploy with approval gate

- **Status**: pending
- On tag creation (vX.Y.Z): build images, wait for manual approval, then deploy to prod
- GitHub Actions environment with required reviewers
- Post-deploy verification (pod status, lobwife health)

### Phase 4: Selective builds

- **Status**: pending
- Detect changed paths to skip unnecessary builds
- `containers/base/**` or `src/common/**` → rebuild all
- `src/lobboss/**` or `containers/lobboss/**` → rebuild lobboss only
- `infra/**` → skip image builds, flag for manual terraform review

## Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|

## Scratch

- Current `lobmob build <target>` uses local Docker buildx with amd64 builder. GHA runners are natively amd64, so no cross-compile overhead
- GHCR auth in GHA is trivial — `GITHUB_TOKEN` has push access to the repo's packages
- DO kubeconfig can be generated via `doctl kubernetes cluster kubeconfig save` — needs DO API token in GHA secrets
- Could use `dorny/paths-filter` action for selective builds
- Lobsigliere image is rarely rebuilt — consider excluding from default build matrix
- Alternative to GHA: keep manual builds but add a pre-push hook or `lobmob deploy` check that warns if images are stale (compare git SHA in image label vs current HEAD)

## Related

- [Roadmap](../roadmap.md)
- [Scratch Sheet](../planning-scratch-sheet.md)
